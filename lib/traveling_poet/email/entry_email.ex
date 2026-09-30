defmodule TravelingPoet.Email.EntryEmail do
  @moduledoc """
  The email a reader gets when their poet publishes: the day and place, the
  poet's own teaser, the day's drawing, one link to the page, and a one-click
  way to stop. Pure (`build/2` takes everything it shows) so it is tested
  without a mailer.

  The drawing is linked with a signed `?sig=` (`MediaController`), so it
  shows for a private journal too without making the image public.

  It reads as a note from the poet, not a newsletter: sent as "Nam via
  Traveling Poet", the page title as the subject, plain text and one
  drawing, an ordinary link, one quiet line to stop. The first version had a
  brand sender, a coloured button, a tinted page and a branded footer, and
  Gmail filed it under Promotions.
  """

  alias TravelingPoet.Email

  alias TravelingPoet.WebPush

  @doc """
  `%{to, subject, html, text, headers}` for one entry. `assigns`: `user`,
  `poet`, `entry`, `day`, `drawing_url` (or nil), `page_url`,
  `unsubscribe_url`.
  """
  def build(%{user: user, poet: poet, entry: entry, day: day} = a) do
    push = WebPush.entry_payload(poet, entry, day)
    title = present(entry.title)
    subject = title || push.title
    teaser = push.body

    %{
      to: user.email,
      from: Email.from_poet(poet.name),
      subject: subject,
      html: html(a, push.title, title, teaser),
      text: text(a, push.title, title, teaser),
      # One-click unsubscribe (RFC 8058): mail apps show their own button.
      headers: %{
        "List-Unsubscribe" => "<#{a.unsubscribe_url}>",
        "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click"
      }
    }
  end

  defp html(a, heading, title, teaser) do
    drawing =
      if a[:drawing_url],
        do:
          ~s(<p><a href="#{esc(a.page_url)}"><img src="#{esc(a.drawing_url)}" alt="#{esc(title || heading)}" width="480" style="max-width:100%;height:auto"></a></p>),
        else: ""

    """
    <!doctype html>
    <html><body style="font-family:Georgia,'Times New Roman',serif;font-size:16px;line-height:1.5;color:#222">
    <div style="max-width:560px">
    <p>#{esc(heading)}</p>
    #{if title, do: "<p><b>#{esc(title)}</b></p>", else: ""}
    <p>#{esc(teaser)}</p>
    #{drawing}
    <p><a href="#{esc(a.page_url)}">Read today's page</a></p>
    <p style="font-size:13px;color:#777">A new page from #{esc(a.poet.name)} each day. <a href="#{esc(a.unsubscribe_url)}" style="color:#777">Stop these emails</a></p>
    </div>
    </body></html>
    """
  end

  defp text(a, heading, title, teaser) do
    [
      heading,
      title,
      "",
      teaser,
      "",
      "Read today's page: #{a.page_url}",
      "",
      "A new page from #{a.poet.name} each day.",
      "Stop these emails: #{a.unsubscribe_url}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp present(nil), do: nil
  defp present(s), do: if(String.trim(s) == "", do: nil, else: s)
end
