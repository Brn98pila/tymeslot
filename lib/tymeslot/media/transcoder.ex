defmodule Tymeslot.Media.Transcoder do
  @moduledoc """
  Production video transcoder using ffmpeg.
  Generates responsive variants from uploaded video files.
  """

  @behaviour Tymeslot.Media.TranscoderBehaviour

  require Logger

  # How much of a failed run's ffmpeg output to keep in the log.
  @error_excerpt_chars 500

  # How much of ffmpeg's output a run holds on to while it encodes. The reason
  # for a failure is always the last thing written, and a long encode writes
  # a progress line every half second.
  @output_tail_bytes 16_384

  # The longest one variant's encode may run before it is killed. VP9 is the
  # slow one: a 1080p clip takes about four times its own length to encode on
  # a 12-core box, so a 100 MB upload at a low bitrate (several minutes of
  # footage) needs tens of minutes on a small self-hosted one. Generous on
  # purpose: this bounds a stalled ffmpeg, not a slow one.
  @variant_timeout :timer.minutes(45)

  @variant_definitions [
    %{
      suffix: "-desktop.webm",
      format: "webm",
      max_height: 1080,
      codec: "libvpx-vp9",
      type: "video/webm",
      media: "(min-width: 1024px)"
    },
    %{
      suffix: "-desktop.mp4",
      format: "mp4",
      max_height: 1080,
      codec: "libx264",
      type: "video/mp4",
      media: "(min-width: 1024px)"
    },
    %{
      suffix: "-mobile.mp4",
      format: "mp4",
      max_height: 720,
      codec: "libx264",
      type: "video/mp4",
      media: "(max-width: 1023px)"
    },
    %{
      suffix: "-low.mp4",
      format: "mp4",
      max_height: 480,
      codec: "libx264",
      type: "video/mp4",
      media: "(max-width: 480px)"
    }
  ]

  @spec variant_definitions() :: [map()]
  def variant_definitions, do: @variant_definitions

  @doc """
  The longest a single `transcode/3` call runs before ffmpeg is killed and it
  returns `{:error, :timeout}`. Override per call with the `:timeout` option.
  """
  @spec variant_timeout() :: pos_integer()
  def variant_timeout, do: @variant_timeout

  @spec derive_variant_paths(String.t()) :: [String.t()]
  def derive_variant_paths(original_path) do
    base = Path.rootname(original_path)
    Enum.map(@variant_definitions, fn %{suffix: suffix} -> base <> suffix end)
  end

  @impl Tymeslot.Media.TranscoderBehaviour
  def available? do
    System.find_executable("ffmpeg") != nil
  end

  @impl Tymeslot.Media.TranscoderBehaviour
  def transcode(source_path, output_path, opts) do
    if File.exists?(source_path) do
      run_ffmpeg(source_path, output_path, opts)
    else
      {:error, :source_missing}
    end
  end

  defp run_ffmpeg(source_path, output_path, opts) do
    codec = Keyword.fetch!(opts, :codec)
    max_height = Keyword.fetch!(opts, :max_height)
    format = Keyword.fetch!(opts, :format)

    timeout = Keyword.get(opts, :timeout, @variant_timeout)

    args = build_ffmpeg_args(source_path, output_path, codec, max_height, format)

    case run_ffmpeg_bounded(args, timeout) do
      {:exit, 0, _output} ->
        :ok

      {:exit, exit_code, output} ->
        transcode_failure(source_path, output_path, output, exit_code)

      :timeout ->
        Logger.error("ffmpeg transcode timed out and was killed",
          timeout_ms: timeout,
          source: source_path,
          output_path: output_path
        )

        {:error, :timeout}

      :not_found ->
        {:error, "ffmpeg not available"}
    end
  end

  # `System.cmd/3` has no timeout, and the OS process it starts outlives a
  # caller that gives up on it. A port hands over the OS pid, so a run that
  # overstays `timeout` is killed outright rather than left encoding (or
  # stalled) with nobody waiting for it.
  defp run_ffmpeg_bounded(args, timeout) do
    case System.find_executable("ffmpeg") do
      nil ->
        :not_found

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ])

        # nil once ffmpeg has already exited; its exit status is then
        # waiting in the mailbox and nothing will need killing.
        os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid
        deadline = System.monotonic_time(:millisecond) + timeout
        await_exit(port, os_pid, deadline, "")
    end
  end

  defp await_exit(port, os_pid, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        await_exit(port, os_pid, deadline, keep_tail(output <> data))

      {^port, {:exit_status, status}} ->
        {:exit, status, output}
    after
      remaining ->
        kill(port, os_pid)
        :timeout
    end
  end

  defp keep_tail(output) when byte_size(output) <= @output_tail_bytes, do: output

  defp keep_tail(output),
    do: binary_part(output, byte_size(output) - @output_tail_bytes, @output_tail_bytes)

  # Through `sh`'s builtin `kill` by absolute path: a slim runtime image need
  # not ship a `kill` binary, and every one ships `/bin/sh`. The pid is an
  # integer the port reported, never input.
  defp kill(port, os_pid) do
    if is_integer(os_pid) do
      System.cmd("/bin/sh", ["-c", "kill -KILL #{os_pid}"], stderr_to_stdout: true, env: [])
    end

    # The port reports the killed process's exit and closes itself; close it
    # here only if that never comes (no pid to kill, or a kill that failed).
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      1_000 -> if Port.info(port), do: Port.close(port)
    end
  end

  # A background video the owner replaces mid-encode is deleted underneath the
  # running job, and ffmpeg reports that as a plain non-zero exit like any other
  # error. Re-checking the source separates "the user moved on" — which no retry
  # can fix and which nobody should be alerted about — from a genuine encode
  # failure.
  defp transcode_failure(source_path, output_path, output, exit_code) do
    if File.exists?(source_path) do
      Logger.error("ffmpeg transcode failed",
        exit_code: exit_code,
        source: source_path,
        output_path: output_path,
        ffmpeg_output: ffmpeg_error_excerpt(output)
      )

      {:error, "ffmpeg exited with status #{exit_code}"}
    else
      Logger.info("Video source removed while transcoding, abandoning variant",
        source: source_path,
        output_path: output_path
      )

      {:error, :source_missing}
    end
  end

  # ffmpeg opens with its version banner and the whole `./configure` line, so
  # the first bytes of a failed run say nothing about why it failed. The reason
  # is always the last thing written.
  defp ffmpeg_error_excerpt(output) do
    output
    |> String.trim_trailing()
    |> String.slice(-@error_excerpt_chars, @error_excerpt_chars)
  end

  defp build_ffmpeg_args(source, output, codec, max_height, format) do
    # ffmpeg copies the source's metadata into its output by default, so
    # without `-map_metadata -1` a variant would republish the location and
    # capture time the upload was stripped of.
    # `-nostdin`: nothing is ever typed at it, and an ffmpeg that reads stdin
    # can stop to wait for input that never comes.
    base_args = [
      "-nostdin",
      "-i",
      source,
      "-y",
      "-an",
      "-map_metadata",
      "-1",
      "-map_chapters",
      "-1"
    ]

    codec_args =
      case format do
        "webm" ->
          ["-c:v", codec, "-b:v", "1M", "-crf", "30"]

        "mp4" ->
          ["-c:v", codec, "-preset", "medium", "-crf", "23", "-movflags", "+faststart"]
      end

    scale_args = ["-vf", "scale=-2:'min(#{max_height},ih)'"]

    base_args ++ codec_args ++ scale_args ++ [output]
  end
end
