defmodule TravelingPoet.Illustrations.LetterboxTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias TravelingPoet.Illustrations.Letterbox

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  # A row of near-black pixels, the way the bars came back (never above 13)
  defp bar(w, bpp), do: for(x <- 1..w, into: <<>>, do: dark(rem(x, 14), bpp))

  defp scene(w, y, bpp),
    do: for(x <- 1..w, into: <<>>, do: pixel(rem(x * 37 + y * 11, 200) + 40, bpp))

  defp dark(v, 3), do: <<v, div(v, 2), v>>
  defp dark(v, 4), do: <<v, div(v, 2), v, 255>>

  defp pixel(v, 3), do: <<v, 255 - v, rem(v * 7, 256)>>
  defp pixel(v, 4), do: <<v, 255 - v, rem(v * 7, 256), 255>>

  # Encodes rows as a PNG, every row with `filter`, so the decoder is checked
  # against an encoder written independently of it.
  defp png(rows, filter, bpp \\ 3) do
    w = div(byte_size(hd(rows)), bpp)
    stride = byte_size(hd(rows))

    {filtered, _} =
      Enum.map_reduce(rows, :binary.copy(<<0>>, stride), fn row, prev ->
        {[filter, apply_filter(filter, row, prev, bpp)], row}
      end)

    color = if bpp == 3, do: 2, else: 6

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<w::32, length(rows)::32, 8, color, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(filtered)),
      chunk("IEND", <<>>)
    ])
  end

  defp apply_filter(0, row, _prev, _bpp), do: row

  defp apply_filter(f, row, prev, bpp) do
    r = :binary.bin_to_list(row)
    p = :binary.bin_to_list(prev)

    for i <- 0..(length(r) - 1), into: <<>> do
      x = Enum.at(r, i)
      a = if i >= bpp, do: Enum.at(r, i - bpp), else: 0
      b = Enum.at(p, i)
      c = if i >= bpp, do: Enum.at(p, i - bpp), else: 0

      pred =
        case f do
          1 -> a
          2 -> b
          3 -> (a + b) >>> 1
          4 -> paeth(a, b, c)
        end

      <<x - pred &&& 255>>
    end
  end

  defp paeth(a, b, c) do
    p = a + b - c

    cond do
      abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - c) -> a
      abs(p - b) <= abs(p - c) -> b
      true -> c
    end
  end

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]

  # The trimmed PNG is written unfiltered, so its rows read straight out
  defp rows_of(@signature <> rest) do
    <<_::32, "IHDR", w::32, h::32, _::binary-5, _crc::32, rest::binary>> = rest
    <<len::32, "IDAT", idat::binary-size(len), _::binary>> = rest
    raw = :zlib.uncompress(idat)
    stride = div(byte_size(raw), h) - 1
    rows = for y <- 0..(h - 1), do: binary_part(raw, y * (stride + 1) + 1, stride)
    {w, h, rows}
  end

  defp letterboxed(w, h, top, bottom, bpp \\ 3) do
    for y <- 0..(h - 1) do
      if y < top or y >= h - bottom, do: bar(w, bpp), else: scene(w, y, bpp)
    end
  end

  test "a drawing padded with black bars comes back without them, whatever the PNG filter" do
    rows = letterboxed(12, 20, 4, 3)
    middle = rows |> Enum.drop(4) |> Enum.take(13)

    for filter <- 0..4 do
      assert {:ok, trimmed, %{top: 4, bottom: 3}} = Letterbox.trim(png(rows, filter))
      assert rows_of(trimmed) == {12, 13, middle}
      assert Letterbox.trim(trimmed) == :unchanged
    end
  end

  test "RGBA is read by its colour, not its alpha" do
    rows = letterboxed(8, 20, 3, 3, 4)
    assert {:ok, trimmed, %{top: 3, bottom: 3}} = Letterbox.trim(png(rows, 4, 4))
    assert {8, 14, _} = rows_of(trimmed)
  end

  test "a hairline dark border is not a letterbox" do
    rows = letterboxed(6, 100, 1, 1)
    assert Letterbox.trim(png(rows, 1)) == :unchanged
  end

  test "an image that is mostly dark is left alone" do
    rows = letterboxed(6, 20, 7, 7)
    assert Letterbox.trim(png(rows, 2)) == :unchanged
  end

  test "a drawing with no bars, or anything that is not a PNG this reads, is unchanged" do
    assert Letterbox.trim(png(letterboxed(6, 10, 0, 0), 4)) == :unchanged
    assert Letterbox.trim(<<0xFF, 0xD8, 0xFF, 0xE0>>) == :unchanged
    assert Letterbox.trim(@signature <> "garbage") == :unchanged
    assert Letterbox.trim(nil) == :unchanged
  end
end
