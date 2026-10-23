defmodule TravelingPoetWeb.ShareComponents do
  @moduledoc """
  The share menu beside a page's heading: one quiet icon button, like the
  marker menu, that opens the phone's share sheet or hands over the page's
  link. Readers had no way to get a page's URL out of the app (Udi,
  2026-10-18: "I'd like to share a journal page with a friend or in
  Twitter"), the app hides the address bar.

  The link is the public page, `/p/:slug/:date`, which works only while the
  poet's journal is public; an owner whose journal is private is told so and
  pointed at Settings instead of being handed a link that opens a 404.
  """
  use Phoenix.Component
  use Gettext, backend: TravelingPoetWeb.Gettext
  use TravelingPoetWeb, :verified_routes

  import TravelingPoetWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :url, :string, required: true, doc: "the page's public URL, absolute"
  attr :title, :string, required: true, doc: "what the share sheet and the post lead with"
  attr :text, :string, default: nil, doc: "a line under the title: the teaser"
  attr :public?, :boolean, default: true, doc: "false shows the owner the Settings note instead"

  @doc "Share this page: the phone's sheet, the link, X, WhatsApp, email."
  def share_menu(assigns) do
    assigns = assign(assigns, :post, post_text(assigns.title, assigns.text))

    ~H"""
    <details
      id={@id}
      class="dropdown dropdown-end marker-menu share-menu"
      phx-hook="ShareMenu"
      data-url={@url}
      data-title={@title}
      data-text={@post}
    >
      <summary
        class="marker-menu-btn"
        title={dgettext("journal", "Share this page")}
        aria-label={dgettext("journal", "Share this page")}
      >
        <.icon name="hero-share" class="size-4" />
      </summary>
      <ul class="dropdown-content marker-menu-list">
        <%= if @public? do %>
          <li class="marker-menu-title">{dgettext("journal", "Share this page")}</li>
          <li hidden data-share-native>
            <button type="button" class="marker-menu-item" data-share>
              <.icon name="hero-arrow-up-tray" class="size-4" />
              <span>{dgettext("journal", "Share...")}</span>
            </button>
          </li>
          <li>
            <button type="button" class="marker-menu-item" data-copy>
              <.icon name="hero-link" class="size-4" />
              <span data-copy-label>{dgettext("journal", "Copy link")}</span>
            </button>
          </li>
          <li>
            <a
              href={"https://twitter.com/intent/tweet?" <> URI.encode_query(%{"text" => @post, "url" => @url})}
              target="_blank"
              rel="noopener noreferrer"
              class="marker-menu-item"
              phx-click={close(@id)}
            >
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
              <span>{dgettext("journal", "Post on X")}</span>
            </a>
          </li>
          <li>
            <a
              href={"https://wa.me/?" <> URI.encode_query(%{"text" => @post <> " " <> @url})}
              target="_blank"
              rel="noopener noreferrer"
              class="marker-menu-item"
              phx-click={close(@id)}
            >
              <.icon name="hero-device-phone-mobile" class="size-4" />
              <span>WhatsApp</span>
            </a>
          </li>
          <li>
            <a
              href={"mailto:?" <> URI.encode_query(%{"subject" => @title, "body" => @post <> "\n" <> @url}, :rfc3986)}
              class="marker-menu-item"
              phx-click={close(@id)}
            >
              <.icon name="hero-envelope" class="size-4" />
              <span>{dgettext("journal", "Email")}</span>
            </a>
          </li>
        <% else %>
          <li class="marker-menu-title">
            {dgettext(
              "journal",
              "Your journal is private, so this page has no link others can open."
            )}
          </li>
          <li>
            <.link navigate={~p"/settings"} class="marker-menu-item">
              <.icon name="hero-cog-6-tooth" class="size-4" />
              <span>{dgettext("journal", "Make it public in Settings")}</span>
            </.link>
          </li>
        <% end %>
      </ul>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :url, :string, required: true, doc: "the invite link, absolute"
  attr :title, :string, required: true
  attr :text, :string, required: true, doc: "the message the link travels with"

  @doc """
  An invite's buttons, in the open (card-126): the phone's share sheet, copy,
  WhatsApp, email. The same `ShareMenu` hook as the menu above, on a row.
  """
  def invite_actions(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="ShareMenu"
      data-url={@url}
      data-title={@title}
      data-text={@text}
      class="flex flex-wrap items-center gap-2"
    >
      <span hidden data-share-native>
        <button type="button" class="btn btn-primary btn-sm" data-share>
          <.icon name="hero-arrow-up-tray" class="size-4" />
          {dgettext("journal", "Invite a friend")}
        </button>
      </span>
      <button type="button" class="btn btn-outline btn-sm" data-copy>
        <.icon name="hero-link" class="size-4" />
        <span data-copy-label>{dgettext("journal", "Copy link")}</span>
      </button>
      <a
        href={"https://wa.me/?" <> URI.encode_query(%{"text" => @text <> " " <> @url})}
        target="_blank"
        rel="noopener noreferrer"
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-device-phone-mobile" class="size-4" /> WhatsApp
      </a>
      <a
        href={"mailto:?" <> URI.encode_query(%{"subject" => @title, "body" => @text <> "\n" <> @url}, :rfc3986)}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-envelope" class="size-4" />
        {dgettext("journal", "Email")}
      </a>
    </div>
    """
  end

  @doc "The message an invite travels with, for a reader's own poet."
  def invite_text(poet_name) do
    dgettext(
      "journal",
      "My poet %{poet} travels the world and writes me an illustrated page every day. Start a poet of your own with %{credits} extra credits:",
      poet: poet_name,
      credits: TravelingPoet.Referrals.referral_credits()
    )
  end

  @doc """
  The address an owner shares (card-126): their public page with their invite
  code on it, so a friend who starts a poet from there counts as invited; a
  private journal shares the bare invite link instead.
  """
  def invite_url(poet, entry, code) do
    if poet.is_public && entry,
      do: url(~p"/p/#{poet.slug}/#{Date.to_iso8601(entry.entry_date)}?#{[ref: code]}"),
      else: url(~p"/i/#{code}")
  end

  @doc "The line a post or a message leads with: the title, then the teaser."
  def post_text(title, nil), do: title
  def post_text(title, ""), do: title
  def post_text(title, text), do: "#{title}. #{text}"

  # <details> does not close itself when an item is a link.
  defp close(id), do: JS.remove_attribute("open", to: "##{id}")
end
