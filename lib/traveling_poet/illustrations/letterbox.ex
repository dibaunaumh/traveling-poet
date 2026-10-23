defmodule TravelingPoet.Illustrations.Letterbox do
  @moduledoc """
  Trims the black bars a model sometimes paints above and below a drawing.

  Gemini, asked for a scene that "stretches across the whole frame", now and
  then draws it wide and pads the square it returns with solid black: about 1
  in 100 main drawings over two weeks (media 1350, 1625, 2260), a third of the
  image black, shown on the page as a letterboxed photo. The prompt asks for
  no bars, but the model cannot be relied on, so the app trims what arrives.

  A bar row is one whose every pixel is near black (no channel above
  24): watercolour content never fills a whole row that dark, and the
  bars measured were never above 13. Only bars touching the top or bottom
  edge are cut, and only when together they are a real band, so a dark
  border of a pixel or two is left alone.

  Pure Elixir (`:zlib` and binaries; the app has no image library), for
  8-bit, non-interlaced RGB and RGBA PNGs, which is what the models return.
  Anything else comes back `:unchanged`.
  """

  import Bitwise

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @dark 24
  # Bars smaller than this share of the height are a border, not a letterbox
  @min_band 0.06
  # Never keep less than this share: an image that is mostly black is a
  # night scene or a failed render, not a padded one
  @min_keep 0.4

  @doc """
  `{:ok, png, %{top: rows, bottom: rows}}` with the bars cut away, or
  `:unchanged` when there are none (or the image is not a PNG this reads).
  """
  def trim(@signature <> chunks) do
    with {:ok, ihdr, idat} <- read_chunks(chunks, nil, []),
         %{width: w, height: h, bpp: bpp} <- header(ihdr),
         {:ok, rows} <- decode_rows(idat, w * bpp, bpp, h),
         {top, bottom} <- bands(rows, bpp),
         true <- top + bottom >= h * @min_band and h - top - bottom >= h * @min_keep do
      kept = rows |> Enum.drop(top) |> Enum.take(h - top - bottom)
      {:ok, encode(ihdr, h - top - bottom, kept), %{top: top, bottom: bottom}}
    else
      _ -> :unchanged
    end
  end

  def trim(_), do: :unchanged

  defp read_chunks(
         <<len::32, type::binary-4, data::binary-size(len), _crc::32, rest::binary>>,
         ihdr,
         idat
       ) do
    case type do
      "IHDR" -> read_chunks(rest, data, idat)
      "IDAT" -> read_chunks(rest, ihdr, [idat | data])
      "IEND" when is_binary(ihdr) -> {:ok, ihdr, IO.iodata_to_binary(idat)}
      _ -> read_chunks(rest, ihdr, idat)
    end
  end

  defp read_chunks(_, _, _), do: :error

  defp header(<<w::32, h::32, 8, color, 0, 0, 0>>) when color in [2, 6] do
    %{width: w, height: h, bpp: if(color == 2, do: 3, else: 4)}
  end

  defp header(_), do: :error

  defp decode_rows(idat, stride, bpp, h) do
    raw = :zlib.uncompress(idat)

    if byte_size(raw) == h * (stride + 1) do
      {rows, _} =
        Enum.map_reduce(0..(h - 1), :binary.copy(<<0>>, stride), fn y, prev ->
          <<filter, line::binary-size(stride)>> = binary_part(raw, y * (stride + 1), stride + 1)
          row = unfilter(filter, line, prev, bpp)
          {row, row}
        end)

      {:ok, rows}
    else
      :error
    end
  rescue
    _ -> :error
  end

  # PNG filters (spec section 9): each byte is predicted from its left
  # neighbour a, the byte above b and the one above-left c.
  defp unfilter(0, line, _prev, _bpp), do: line

  defp unfilter(2, line, prev, _bpp) do
    for {x, b} <- Enum.zip(:binary.bin_to_list(line), :binary.bin_to_list(prev)),
        into: <<>>,
        do: <<x + b &&& 255>>
  end

  defp unfilter(filter, line, prev, bpp) when filter in [1, 3, 4] do
    zeros = List.duplicate(0, bpp)
    unfilter(filter, :binary.bin_to_list(line), :binary.bin_to_list(prev), zeros, zeros, [])
  end

  defp unfilter(_, _, _, _), do: raise(ArgumentError, "unknown PNG filter")

  defp unfilter(_f, [], _, _, _, acc), do: acc |> Enum.reverse() |> :binary.list_to_bin()

  defp unfilter(f, [x | xs], [b | bs], [a | as], [c | cs], acc) do
    out = x + predict(f, a, b, c) &&& 255
    unfilter(f, xs, bs, as ++ [out], cs ++ [b], [out | acc])
  end

  defp predict(1, a, _b, _c), do: a
  defp predict(3, a, b, _c), do: (a + b) >>> 1

  defp predict(4, a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  defp bands(rows, bpp) do
    dark = Enum.map(rows, &dark_row?(&1, bpp))
    top = Enum.take_while(dark, & &1) |> length()
    bottom = dark |> Enum.reverse() |> Enum.take_while(& &1) |> length()
    {top, bottom}
  end

  defp dark_row?(row, 3), do: dark_pixels?(row)

  # RGBA: the alpha byte says nothing about colour, so drop it first
  defp dark_row?(row, 4),
    do: dark_pixels?(for <<r, g, b, _a <- row>>, into: <<>>, do: <<r, g, b>>)

  defp dark_pixels?(bytes), do: Enum.max(:binary.bin_to_list(bytes)) <= @dark

  defp encode(ihdr, height, rows) do
    <<w::32, _h::32, rest::binary>> = ihdr
    idat = rows |> Enum.map(&[0, &1]) |> :zlib.compress()

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<w::32, height::32, rest::binary>>),
      chunk("IDAT", idat),
      chunk("IEND", <<>>)
    ])
  end

  defp chunk(type, data) do
    [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
  end
end
