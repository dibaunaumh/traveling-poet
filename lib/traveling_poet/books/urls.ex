defmodule TravelingPoet.Books.Urls do
  @moduledoc """
  Absolute links back into the site, for anything that leaves it: a printed
  page, a PDF, a Telegram note. One rule for where an entry lives (a public
  poet's page is under `/p/:slug`, a private one's under `/journal`) so the
  book and the notifiers cannot disagree.
  """

  @doc "The site's absolute base, from `:phoenix_url`; empty when unset (tests)."
  def base, do: Application.get_env(:traveling_poet, :phoenix_url, "")

  @doc "The entry's own page. Never the journal index, which shows whatever is newest by the time it is opened."
  def entry_url(poet, %{entry_date: date}) do
    if poet.is_public,
      do: "#{base()}/p/#{poet.slug}/#{date}",
      else: "#{base()}/journal/#{date}"
  end

  def journal_url(%{is_public: true, slug: slug}), do: "#{base()}/p/#{slug}"
  def journal_url(_poet), do: "#{base()}/journal"

  def guide_url(%{is_public: true, slug: slug}), do: "#{base()}/p/#{slug}/guide"
  def guide_url(_poet), do: "#{base()}/guide"

  def media_url(%{id: id}), do: "#{base()}/media/#{id}"
end
