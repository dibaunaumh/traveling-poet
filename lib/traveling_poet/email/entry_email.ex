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

  With `page` (card-124, `users.email_full_page`), the email carries the
  whole page instead of the teaser: `%{sections, media, extra_media,
  spot_media, places, guide_url, media_url}`, as `Journal.EntryBundle`
  loads it, with `media_url` a function from a media id to a signed absolute
  URL, so a private journal's drawings show. The prose goes through the
  page's own renderer (`NotebookComponents.raw_markdown/3`), so the same
  sanitizing and the same rule on images hold in the mail.

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

    # The whole page, when asked for: the drawing, then the sections in the
    # poet's order and the day's places; the teaser gives way to the prose.
    body =
      case a[:page] do
        nil -> "<p#{teaser_lang}>#{esc(teaser)}</p>\n#{drawing}"
        page_data -> page_html(page_data, a.entry)
      end

    read_words =
      if a[:page],
        do: dgettext("notify", "Open today's page"),
        else: dgettext("notify", "Read today's page")

    """
    <!doctype html>
    <html lang="#{locale}" dir="#{Locale.dir(locale)}"><body style="font-family:Georgia,'Times New Roman',serif;font-size:16px;line-height:1.5;color:#222">
    <div lang="#{locale}" dir="#{Locale.dir(locale)}" style="max-width:560px">
    <p>#{esc(heading)}</p>
    #{if title, do: "<p#{page}><b>#{esc(title)}</b></p>", else: ""}
    #{body}
    <p><a href="#{esc(a.page_url)}">#{read_words}</a>#{listen}</p>
    <p style="font-size:13px;color:#777">#{dgettext("notify", "A new page from %{poet} each day.", poet: esc(a.poet.name))} <a href="#{esc(a.unsubscribe_url)}" style="color:#777">#{dgettext("notify", "Stop these emails")}</a></p>
    </div>
    </body></html>
    """
  end

  @img_style ~s(width="480" style="max-width:100%;height:auto")

  defp page_html(page, entry) do
    lang = page_lang(entry)
    url = page.media_url

    drawings =
      (illustration_media(page) ++ Map.get(page, :extra_media, []))
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn m ->
        ~s(<p><img src="#{esc(url.(m.id))}" alt="#{esc(m.alt_text || "")}" #{@img_style}></p>)
      end)

    sections =
      page.sections
      |> Enum.reject(&(&1.kind == "illustration"))
      |> Enum.map(fn s ->
        heading =
          if present(s.title),
            do: ~s(<p#{lang} style="margin-bottom:0"><b>#{esc(s.title)}</b></p>),
            else: ""

        prose = prose_html(s.body, Map.get(page, :spot_media, %{}), url)

        style = if s.kind == "poem", do: ~s( style="white-space:pre-line"), else: ""
        heading <> ~s(<div#{lang}#{style}>#{prose}</div>)
      end)

    places =
      case Map.get(page, :places, []) do
        [] ->
          ""

        places ->
          items =
            Enum.map_join(places, "\n", fn p ->
              detail = [p.category, p.address] |> Enum.filter(&present/1) |> Enum.join(", ")

              ~s(<li><b>#{esc(p.name)}</b>#{if detail != "", do: " &middot; " <> esc(detail), else: ""}</li>)
            end)

          ~s(<p style="margin-bottom:0"><b>#{dgettext("notify", "Where to go")}</b></p><ul>#{items}</ul>) <>
            ~s(<p><a href="#{esc(page.guide_url)}">#{dgettext("notify", "Open the guide")}</a></p>)
      end

    Enum.join(drawings ++ sections ++ [places], "\n")
  end

  defp illustration_media(page) do
    media = Map.get(page, :media, %{})

    page.sections
    |> Enum.filter(&(&1.kind == "illustration"))
    |> Enum.map(&Map.get(media, &1.media_id))
    |> Enum.reject(&is_nil/1)
  end

  # The page's renderer: sanitized, and only this entry's own spot drawings
  # come through as images. Their paths are then signed and made absolute,
  # since a mail app has no session.
  defp prose_html(body, spot_media, url) do
    body
    |> TravelingPoetWeb.NotebookComponents.raw_markdown(spot_media, [])
    |> case do
      {:safe, _} = safe -> Phoenix.HTML.safe_to_string(safe)
      text when is_binary(text) -> esc(text)
    end
    |> String.replace(~r{src="/media/(\d+)"}, fn match ->
      [_, id] = Regex.run(~r{src="/media/(\d+)"}, match)
      ~s(src="#{esc(url.(String.to_integer(id)))}" #{@img_style})
    end)
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
      page_text(a[:page], teaser),
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

  defp page_text(nil, teaser), do: teaser

  defp page_text(page, _teaser) do
    sections =
      page.sections
      |> Enum.reject(&(&1.kind == "illustration"))
      |> Enum.map(fn s ->
        [if(present(s.title), do: s.title), s.body]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")
      end)

    places =
      case Map.get(page, :places, []) do
        [] ->
          []

        places ->
          [
            dgettext("notify", "Where to go") <>
              "\n" <> Enum.map_join(places, "\n", &("- " <> &1.name))
          ]
      end

    Enum.join(sections ++ places, "\n\n")
  end

  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp present(nil), do: nil
  defp present(s), do: if(String.trim(s) == "", do: nil, else: s)
end
