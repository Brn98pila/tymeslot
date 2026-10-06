defmodule Tymeslot.Bookings.MeetingLinks do
  @moduledoc """
  The public view, reschedule and cancel links of a booking.

  The links are built when they are rendered, from the meeting's uid, the
  organiser's username *now* and the application's base URL *now*. A booking
  also stores a copy of them (`view_url`, `reschedule_url`, `cancel_url`),
  written once at booking time; that copy goes stale as soon as the host
  changes their username or the deployment moves domain, so nothing that
  shows a link to anyone reads it.

  A host without a username gets the uid-only form (`/meeting/:uid/cancel`),
  which the router resolves to the host's current page once they have one.
  """

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.UrlBuilder

  @type links :: %{
          view_url: String.t() | nil,
          reschedule_url: String.t() | nil,
          cancel_url: String.t() | nil
        }

  @type page :: :cancel | :cancel_confirmed | :reschedule

  @suffixes %{
    view: "",
    cancel: "/cancel",
    cancel_confirmed: "/cancel-confirmed",
    reschedule: "/reschedule"
  }

  # The pages a link can be resolved to by uid; there is no public view page.
  @pages [:cancel, :cancel_confirmed, :reschedule]

  @doc """
  The links to show for `meeting`.

  A group meeting is the exception: its slot is never cancelled or moved
  through the public uid links, and the links its participants see are their
  own seat links, which `Tymeslot.Meetings.Recipient.as_seen_by/2` lays over
  the struct. Those are returned as the struct carries them.
  """
  @spec for_meeting(map()) :: links()
  def for_meeting(%MeetingSchema{capacity: capacity} = meeting)
      when is_integer(capacity) and capacity > 1 do
    Map.take(meeting, [:view_url, :reschedule_url, :cancel_url])
  end

  def for_meeting(%{uid: uid} = meeting) when is_binary(uid) do
    meeting
    |> Map.get(:organizer_user_id)
    |> current_username()
    |> build(uid)
  end

  # Without a uid there is nothing to link to; whatever the map carries stands.
  def for_meeting(meeting) when is_map(meeting) do
    %{
      view_url: Map.get(meeting, :view_url),
      reschedule_url: Map.get(meeting, :reschedule_url),
      cancel_url: Map.get(meeting, :cancel_url)
    }
  end

  @doc """
  `meeting` with its link fields replaced by `for_meeting/1`, for templates
  that render straight from the meeting struct.
  """
  @spec with_current_links(map()) :: map()
  def with_current_links(meeting) when is_map(meeting),
    do: Map.merge(meeting, for_meeting(meeting))

  @doc """
  The links for a booking with `uid` whose organiser is called `username`.

  Used at booking time to fill the stored columns, and by `for_meeting/1`.
  """
  @spec build(String.t() | nil, String.t()) :: %{
          view_url: String.t(),
          reschedule_url: String.t(),
          cancel_url: String.t()
        }
  def build(username, uid) when is_binary(uid) do
    %{
      view_url: url(username, uid, :view),
      reschedule_url: url(username, uid, :reschedule),
      cancel_url: url(username, uid, :cancel)
    }
  end

  @doc """
  Where `page` for the booking with `uid` lives now, as a path.

  Resolves the organiser by the meeting rather than by any username in the
  link, so a link built before the host renamed themselves, or before they
  had a username at all, still reaches the page. The uid is what authorises
  the page, so answering from it reveals nothing the link did not already
  grant. `{:error, :not_found}` when no meeting has that uid or its organiser
  has no username.
  """
  @spec current_path(String.t(), page()) :: {:ok, String.t()} | {:error, :not_found}
  def current_path(uid, page) when is_binary(uid) and page in @pages do
    case MeetingQueries.organizer_username_by_uid(uid) do
      {:ok, username} -> {:ok, path(username, uid, page)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp url(username, uid, action), do: UrlBuilder.base_url() <> path(username, uid, action)

  defp path(username, uid, action) when is_binary(username) and username != "",
    do: "/#{username}/meeting/#{uid}#{Map.fetch!(@suffixes, action)}"

  defp path(_no_username, uid, action), do: "/meeting/#{uid}#{Map.fetch!(@suffixes, action)}"

  defp current_username(nil), do: nil

  defp current_username(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> profile.username
      {:error, :not_found} -> nil
    end
  end
end
