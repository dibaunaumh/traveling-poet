defmodule TravelingPoet.Narration.Mp3 do
  @moduledoc """
  How long an mp3 runs, read from the bytes: a Xing/Info frame count when
  the file is variable bit rate, else the size over the first frame's bit
  rate (every speech provider in the 2026-10-15 eval streamed constant bit
  rate). Pure; nil when the bytes are not an mp3 we can read.
  """

  import Bitwise

  @bitrates_v1_l3 {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}
  @bitrates_v2_l3 {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}
  @rates_v1 {44_100, 48_000, 32_000, 0}
  @rates_v2 {22_050, 24_000, 16_000, 0}
  @rates_v25 {11_025, 12_000, 8_000, 0}

  @spec duration_seconds(binary) :: pos_integer | nil
  def duration_seconds(bytes) when is_binary(bytes) do
    with {:ok, offset, frame} <- first_frame(bytes, 0) do
      case xing_frames(bytes, offset, frame) do
        nil -> round(byte_size(bytes) * 8 / frame.bitrate)
        frames -> round(frames * frame.samples / frame.rate)
      end
      |> max(1)
    else
      _ -> nil
    end
  end

  # ID3v2 tag first, then frames
  defp first_frame(<<"ID3", _::binary-size(3), s::binary-size(4), _::binary>> = bytes, 0) do
    <<a, b, c, d>> = s
    size = (a <<< 21) + (b <<< 14) + (c <<< 7) + d + 10
    first_frame(bytes, size)
  end

  defp first_frame(bytes, offset) when offset + 4 <= byte_size(bytes) do
    case parse_header(binary_part(bytes, offset, 4)) do
      {:ok, frame} -> {:ok, offset, frame}
      :error -> first_frame(bytes, offset + 1)
    end
  end

  defp first_frame(_bytes, _offset), do: :error

  defp parse_header(
         <<0xFF, 0b111::3, version::2, layer::2, _crc::1, bitrate_i::4, rate_i::2, _pad::1,
           _priv::1, channels::2, _::6>>
       )
       when version != 1 and layer == 1 and bitrate_i not in [0, 15] and rate_i != 3 do
    {bitrates, rates, samples} =
      case version do
        3 -> {@bitrates_v1_l3, @rates_v1, 1152}
        2 -> {@bitrates_v2_l3, @rates_v2, 576}
        0 -> {@bitrates_v2_l3, @rates_v25, 576}
      end

    {:ok,
     %{
       bitrate: elem(bitrates, bitrate_i) * 1000,
       rate: elem(rates, rate_i),
       samples: samples,
       mono?: channels == 3,
       version: version
     }}
  end

  defp parse_header(_), do: :error

  # The Xing/Info header sits after the side info of the first frame.
  defp xing_frames(bytes, offset, frame) do
    side =
      if frame.version == 3,
        do: if(frame.mono?, do: 17, else: 32),
        else: if(frame.mono?, do: 9, else: 17)

    at = offset + 4 + side

    case bytes do
      <<_::binary-size(at), tag::binary-size(4), flags::32, frames::32, _::binary>>
      when tag in ["Xing", "Info"] and (flags &&& 1) == 1 ->
        frames

      _ ->
        nil
    end
  end
end
