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

  use Gettext, backend: TravelingPoetWeb.Gettext

  alias TravelingPoet.{Email, Locale}

  alias TravelingPoet.WebPush

  @doc """
  `%{to, subject, html, text, headers}` for one entry. `assigns`: `user`,
  `poet`, `entry`, `day`, `drawing_url` (or nil), `page_url`,
  `unsubscribe_url`, and `listen?` with `listen_minutes` when the page can
  be read aloud (on demand, from the ring on the page; the minutes are an
  estimate from the words).

  Written in the reader's language (`users.locale`): nothing else sets one
  for a background sender. The page's own words, its title and teaser, carry
  the page's language (`journal_entries.language`), which may differ.
  """
  def build(%{user: user} = a) do
    Locale.with_locale(Map.get(user, :locale), fn -> build_in_locale(a) end)
  end

  defp build_in_locale(%{user: user, poet: poet, entry: entry, day: day} = a) do
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

    locale = Locale.current()
    page = page_lang(a.entry)

    # Translations are the app's own words, so only what goes into them is
    # escaped (an apostrophe stays an apostrophe, as it was in English).
    # The teaser is the page's own words unless the poet wrote none and the
    # app's fallback line stands in for it.
    teaser_lang = if poet_words?(a.entry), do: page, else: ""

    listen =
      if a[:listen?] do
        ~s( &middot; <a href="#{esc(a.page_url)}#listen">#{listen_words(a)}</a>)
      else
        ""
      end

    """
    <!doctype html>
    <html lang="#{locale}" dir="#{Locale.dir(locale)}"><body style="font-family:Georgia,'Times New Roman',serif;font-size:16px;line-height:1.5;color:#222">
    <div lang="#{locale}" dir="#{Locale.dir(locale)}" style="max-width:560px">
    <p>#{esc(heading)}</p>
    #{if title, do: "<p#{page}><b>#{esc(title)}</b></p>", else: ""}
    <p#{teaser_lang}>#{esc(teaser)}</p>
    #{drawing}
    <p><a href="#{esc(a.page_url)}">#{dgettext("notify", "Read today's page")}</a>#{listen}</p>
    <p style="font-size:13px;color:#777">#{dgettext("notify", "A new page from %{poet} each day.", poet: esc(a.poet.name))} <a href="#{esc(a.unsubscribe_url)}" style="color:#777">#{dgettext("notify", "Stop these emails")}</a></p>
    </div>
    </body></html>
    """
  end

  # English said "minutes" for one minute too, and still does
  defp listen_words(a) do
    dngettext(
      "notify",
      "or listen, about %{count} minutes",
      "or listen, about %{count} minutes",
      a[:listen_minutes] || 5
    )
  end

  # ` lang="he" dir="rtl"` for the page's own words, when its language is known
  defp page_lang(entry) do
    case Locale.normalize(Map.get(entry, :language)) do
      nil -> ""
      lang -> ~s( lang="#{lang}" dir="#{Locale.dir(lang)}")
    end
  end

  defp poet_words?(entry), do: present(entry.teaser) != nil or present(entry.title) != nil

  defp text(a, heading, title, teaser) do
    [
      heading,
      title,
      "",
      teaser,
      "",
      dgettext("notify", "Read today's page: %{url}", url: a.page_url),
      if(a[:listen?],
        do:
          dngettext(
            "notify",
            "Or listen, about %{count} minutes: %{url}",
            "Or listen, about %{count} minutes: %{url}",
            a[:listen_minutes] || 5,
            url: "#{a.page_url}#listen"
          )
      ),
      "",
      dgettext("notify", "A new page from %{poet} each day.", poet: a.poet.name),
      dgettext("notify", "Stop these emails: %{url}", url: a.unsubscribe_url)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp present(nil), do: nil
  defp present(s), do: if(String.trim(s) == "", do: nil, else: s)
end
