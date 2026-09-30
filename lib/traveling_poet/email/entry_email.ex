defmodule TravelingPoet.Email.EntryEmail do
  @moduledoc """
  The email a reader gets when their poet publishes: the day and place, the
  poet's own teaser, the day's drawing, one link to the page, and a one-click
  way to stop. Pure (`build/2` takes everything it shows) so it is tested
  without a mailer.

  The drawing is linked with a signed `?sig=` (`MediaController`), so it
  shows for a private journal too without making the image public.
  """

  alias TravelingPoet.WebPush

  @doc """
  `%{to, subject, html, text, headers}` for one entry. `assigns`: `user`,
  `poet`, `entry`, `day`, `drawing_url` (or nil), `page_url`,
  `unsubscribe_url`.
  """
  def build(%{user: user, poet: poet, entry: entry, day: day} = a) do
    push = WebPush.entry_payload(poet, entry, day)
    title = present(entry.title)
    subject = if title, do: "#{push.title}: #{title}", else: push.title
    teaser = push.body

    %{
      to: user.email,
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
          ~s(<p style="margin:20px 0"><a href="#{esc(a.page_url)}"><img src="#{esc(a.drawing_url)}" alt="#{esc(title || heading)}" width="520" style="max-width:100%;height:auto;border-radius:10px"></a></p>),
        else: ""

    """
    <!doctype html>
    <html><body style="margin:0;padding:24px;background:#fbfaf7;color:#222;font-family:Georgia,'Times New Roman',serif">
    <div style="max-width:560px;margin:0 auto">
    <p style="margin:0 0 4px;color:#6b6b6b;font-size:14px">#{esc(heading)}</p>
    #{if title, do: ~s(<h1 style="margin:0 0 12px;font-size:24px;font-weight:normal">#{esc(title)}</h1>), else: ""}
    <p style="margin:0;font-size:17px;line-height:1.5">#{esc(teaser)}</p>
    #{drawing}
    <p style="margin:20px 0"><a href="#{esc(a.page_url)}" style="background:#2f5d62;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-family:Helvetica,Arial,sans-serif;font-size:15px">Read today's page</a></p>
    <p style="margin:32px 0 0;color:#8a8a8a;font-size:12px;font-family:Helvetica,Arial,sans-serif">
    #{esc(a.poet.name)} writes to you once a day from Traveling Poet.
    <a href="#{esc(a.unsubscribe_url)}" style="color:#8a8a8a">Stop these emails</a>
    </p>
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
      "#{a.poet.name} writes to you once a day from Traveling Poet.",
      "Stop these emails: #{a.unsubscribe_url}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp present(nil), do: nil
  defp present(s), do: if(String.trim(s) == "", do: nil, else: s)
end
