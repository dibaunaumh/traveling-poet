defmodule TravelingPoet.Journal.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft published)

  schema "journal_entries" do
    field :entry_date, :date
    field :title, :string
    # The hook for the day's notification: one line the poet writes to make
    # its reader open the entry. The app prefixes the journey day itself.
    field :teaser, :string
    field :place_name, :string
    field :lat, :float
    field :lng, :float
    field :status, :string, default: "draft"
    field :published_at, :utc_datetime
    field :weather, :map, default: %{}
    field :sources, :map, default: %{}
    # Did the poet's own reader actually open this? The only signal a silent
    # user gives, and the difference between "happy and quiet" and "gone".
    field :owner_viewed_at, :utc_datetime
    field :owner_view_count, :integer, default: 0

    belongs_to :poet, TravelingPoet.Poets.Poet
    has_many :sections, TravelingPoet.Journal.Section, foreign_key: :journal_entry_id
    has_many :reactions, TravelingPoet.Journal.Reaction, foreign_key: :journal_entry_id
    has_one :prompt, TravelingPoet.Preferences.EntryPrompt, foreign_key: :journal_entry_id
    # Set when this entry is an excursion into a topic rather than a day at
    # the place. Its own table: the excursion exists before the entry does.
    has_one :excursion, TravelingPoet.Topics.Excursion, foreign_key: :journal_entry_id

    timestamps()
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :poet_id,
      :entry_date,
      :title,
      :teaser,
      :place_name,
      :lat,
      :lng,
      :status,
      :published_at,
      :weather,
      :sources,
      :owner_viewed_at,
      :owner_view_count
    ])
    |> validate_required([:poet_id, :entry_date])
    |> validate_length(:teaser, max: 140)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:poet_id, :entry_date])
  end
end
