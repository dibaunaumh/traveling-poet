defmodule TravelingPoetWeb.BookHTML do
  @moduledoc false
  use TravelingPoetWeb, :html

  import TravelingPoetWeb.BookComponents

  embed_templates "book_html/*"
end
