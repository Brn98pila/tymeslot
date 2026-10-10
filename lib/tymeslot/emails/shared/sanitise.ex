defmodule Tymeslot.Emails.Shared.Sanitise do
  @moduledoc """
  Safety boundary between raw user input and rendered email content.

  Helpers for the two distinct sinks:

  - `sanitize_for_email/1` — HTML-escapes text destined for the MJML/HTML body.
  - `sanitize_multiline_for_email/1`: the same for free text someone wrote
    (a note, a message), keeping its line breaks and capping its length.
  - `sanitize_for_header/1` — strips control characters from values destined
    for headers like Subject so they cannot inject additional headers via
    embedded CR/LF.
  """

  alias Phoenix.HTML
  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Security.UrlValidation

  # Longest free text an email body quotes before truncating it.
  @max_free_text_length 10_000

  @doc """
  Sanitizes text for email display.
  """
  @spec sanitize_for_email(String.t() | nil) :: String.t()
  def sanitize_for_email(nil), do: ""

  def sanitize_for_email(text) when is_binary(text) do
    text
    |> String.trim()
    |> HTML.html_escape()
    |> HTML.safe_to_string()
  end

  @doc """
  HTML-escapes free text for the email body and turns its newlines into
  `<br>`, truncating anything longer than #{@max_free_text_length} characters.

  Escaping, not stripping: the reader sees exactly what was written, markup
  included, and nothing is silently dropped.
  """
  @spec sanitize_multiline_for_email(String.t() | nil) :: String.t()
  def sanitize_multiline_for_email(nil), do: ""

  def sanitize_multiline_for_email(text) when is_binary(text) do
    text
    |> Formatting.truncate(@max_free_text_length)
    |> sanitize_for_email()
    |> String.replace(~r/\r?\n/, "<br>")
  end

  @doc """
  Whether `url` may be linked from an email: an http(s) URL, or a `mailto:`
  address. Every link, button and plain-text action line in an email goes
  through this one rule; an action whose URL fails it is left out.
  """
  @spec safe_url?(term()) :: boolean()
  def safe_url?("mailto:" <> address), do: address != ""
  def safe_url?(url), do: UrlValidation.validate_http_url(url) == :ok

  @doc """
  `url` escaped for an email `href`, or nil when it is missing or not safe to
  link (see `safe_url?/1`). Components render nothing for nil rather than a
  link that goes nowhere.
  """
  @spec sanitize_url(term()) :: String.t() | nil
  def sanitize_url(url) do
    if safe_url?(url), do: sanitize_for_email(url)
  end

  @doc """
  Sanitises a value bound for an email header (typically Subject).

  Replaces ASCII control characters — including CR and LF — with a single
  space and collapses runs of whitespace. This is the boundary that prevents
  email header injection when a user-authored field (meeting title, attendee
  name, etc.) is interpolated into the Subject line: CR/LF in headers would
  otherwise allow an attacker to add their own headers to the outgoing email.
  """
  @spec sanitize_for_header(String.t() | nil) :: String.t()
  def sanitize_for_header(nil), do: ""

  def sanitize_for_header(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
