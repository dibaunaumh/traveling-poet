defmodule TravelingPoet.Preferences.Prompts do
  @moduledoc """
  The question asked under an entry when the poet didn't author one.

  These are the floor, not the ceiling. A poet that names the actual fork it
  took today ("I skipped the museum for the market — want more of that?") will
  always beat a template, but the fleet runs a cheap model with known
  structured-output wobbles, so a missing or malformed agent prompt must never
  mean no prompt at all.

  Options are built from what the poet genuinely varies run to run — the
  section kinds it chooses, how long it writes, how long it stays — so an
  answer maps onto a decision it can actually make tomorrow.
  """

  alias TravelingPoet.Preferences

  @doc """
  A prompt for this entry, avoiding dimensions the profile already covers.
  Returns `%{question:, options: [...], source: "app"}`.
  """
  def default_for(entry, profile \\ []) do
    covered = MapSet.new(profile, & &1.dimension)

    catalogue(entry)
    |> Enum.reject(&MapSet.member?(covered, &1.dimension))
    |> case do
      [] -> catalogue(entry) |> pick(entry)
      remaining -> pick(remaining, entry)
    end
  end

  # Stable per entry: the same entry always shows the same question, so a
  # re-render or a revisit never swaps the question under someone's cursor.
  defp pick(candidates, entry) do
    index = rem(entry.id, length(candidates))
    candidates |> Enum.at(index) |> to_prompt()
  end

  defp to_prompt(%{question: question, options: options, dimension: dimension}) do
    %{
      question: question,
      source: "app",
      options:
        Enum.map(options, fn {id, label, polarity, subject} ->
          %{
            "id" => id,
            "label" => label,
            "dimension" => dimension,
            "polarity" => polarity,
            "key" => Preferences.derive_key(dimension, subject),
            "subject" => subject
          }
        end)
    }
  end

  @doc """
  The question for someone who has stopped opening entries. Asking them to
  choose between museums and markets misses the point — the useful question is
  whether they want this at all, and the honest options include less of it.
  """
  def broad_check_in(_entry) do
    %{
      question: "Still enjoying these?",
      source: "app",
      options: [
        %{
          "id" => "more_like_this",
          "label" => "Yes — more like this",
          "dimension" => "format",
          "polarity" => "seek",
          "key" => Preferences.derive_key("format", "the journal as it is"),
          "subject" => "the journal as it is"
        },
        %{
          "id" => "change_subject",
          "label" => "Write about different things",
          "dimension" => "topic",
          "polarity" => "avoid",
          "key" => Preferences.derive_key("topic", "what the poet writes about now"),
          "subject" => "what the poet writes about now"
        },
        %{
          "id" => "less_often",
          "label" => "Write less often",
          "dimension" => "pace",
          "polarity" => "avoid",
          "key" => Preferences.derive_key("pace", "writing every day"),
          "subject" => "writing every day"
        }
      ]
    }
  end

  @doc """
  The question under one of the first excursions into a topic: was the day
  off the road worth it. "Pause this topic" carries an `effect` the app
  applies on answer (and reverses on undo); only the app may set one, so an
  agent-authored option never reaches `Preferences.answer_prompt/4` with it.
  """
  def excursion_check_in(_entry, excursion) do
    label = (excursion.topic && excursion.topic.label) || "this topic"
    subject = "excursions into #{label}"

    %{
      question: "An excursion into #{label}. Worth the day?",
      source: "app",
      options: [
        %{
          "id" => "more_like_this",
          "label" => "More like this",
          "dimension" => "topic",
          "polarity" => "seek",
          "key" => Preferences.derive_key("topic", subject),
          "subject" => subject
        },
        %{
          "id" => "different_angle",
          "label" => "A different angle",
          "dimension" => "topic",
          "polarity" => "avoid",
          "key" => Preferences.derive_key("topic", "this angle on #{label}"),
          "subject" => "this angle on #{label}"
        },
        %{
          "id" => "pause_topic",
          "label" => "Pause this topic",
          "dimension" => "topic",
          "polarity" => "avoid",
          "key" => Preferences.derive_key("topic", subject),
          "subject" => subject,
          "effect" => %{"pause_topic" => excursion.topic_id}
        }
      ]
    }
  end

  defp catalogue(entry) do
    place = entry.place_name || "here"

    [
      %{
        dimension: "topic",
        question: "What would you like more of?",
        options: [
          {"art", "The art & culture finds", "seek", "art and culture"},
          {"products", "Local things to bring home", "seek", "local products and crafts"},
          {"kindness", "Ways to do some good", "seek", "kindness opportunities"}
        ]
      },
      %{
        dimension: "length",
        question: "Was this the right length?",
        options: [
          {"shorter", "A bit shorter", "avoid", "long entries"},
          {"right", "Just right", "seek", "this length"},
          {"longer", "Go deeper", "seek", "long entries"}
        ]
      },
      %{
        dimension: "pace",
        question: "How's the pace of the journey?",
        options: [
          {"linger", "Stay longer in each place", "seek", "lingering in one place"},
          {"move", "Move on sooner", "avoid", "lingering in one place"}
        ]
      },
      %{
        dimension: "tone",
        question: "What draws you in most?",
        options: [
          {"strange", "The strange and unexpected", "seek", "the strange and unexpected"},
          {"beautiful", "The beautiful and quiet", "seek", "the beautiful and quiet"},
          {"people", "The people and their stories", "seek", "people and their stories"}
        ]
      },
      %{
        dimension: "place",
        question: "More places like #{place}?",
        options: [
          {"more", "Yes, more like this", "seek", "places like #{place}"},
          {"different", "Somewhere quite different", "avoid", "places like #{place}"}
        ]
      }
    ]
  end
end
