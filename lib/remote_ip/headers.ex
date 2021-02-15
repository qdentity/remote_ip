defmodule RemoteIp.Headers do
  use RemoteIp.Debug

  @moduledoc """
  Functions for parsing IPs from multiple types of forwarding headers.
  """

  @doc """
  Extracts all headers with the given names.

  Note that `Plug.Conn` headers are assumed to have been normalized to
  lowercase, so the names you give should be in lowercase as well.

  ## Examples

      iex> [{"x-foo", "foo"}, {"x-bar", "bar"}, {"x-baz", "baz"}]
      ...> |> RemoteIp.Headers.take(["x-foo", "x-baz", "x-qux"])
      [{"x-foo", "foo"}, {"x-baz", "baz"}]

      iex> [{"x-dup", "foo"}, {"x-dup", "bar"}, {"x-dup", "baz"}]
      ...> |> RemoteIp.Headers.take(["x-dup"])
      [{"x-dup", "foo"}, {"x-dup", "bar"}, {"x-dup", "baz"}]
  """

  @spec take(Plug.Conn.headers(), [String.t()]) :: Plug.Conn.headers()

  def take(headers, names) do
    RemoteIp.Debug.log :req do
      headers
    end

    RemoteIp.Debug.log :fwd do
      Enum.filter(headers, fn {name, _} -> name in names end)
    end
  end

  @doc """
  Parses IP addresses out of the given headers.

  For each header name/value pair, the value is parsed for zero or more IP
  addresses by a `RemoteIp.Headers.*` submodule corresponding to the header's
  name. As of this writing, there are only two cases:

  * `"forwarded"` headers are parsed by `RemoteIp.Headers.Forwarded.parse/1`
  * all other headers are parsed by `RemoteIp.Headers.Generic.parse/1`

  The IPs are concatenated together into a single flat list. Importantly, we
  preserve their relative order. That is, each header produce multiple IPs that
  are kept in the order given by that specific header. Then, in the case of
  multiple headers, the concatenated list maintains the same order as the
  headers appeared in the original name/value list.

  Due to the error-safe nature of the parser submodules, headers that do not
  actually contain valid IP addresses should be safely ignored.

  ## Examples

      iex> [{"x-one", "1.2.3.4, 2.3.4.5"}, {"x-two", "3.4.5.6, 4.5.6.7"}]
      ...> |> RemoteIp.Headers.parse()
      [{1, 2, 3, 4}, {2, 3, 4, 5}, {3, 4, 5, 6}, {4, 5, 6, 7}]

      iex> [{"forwarded", "for=1.2.3.4"}, {"x-forwarded-for", "2.3.4.5"}]
      ...> |> RemoteIp.Headers.parse()
      [{1, 2, 3, 4}, {2, 3, 4, 5}]

      iex> [{"accept", "*/*"}, {"user-agent", "ua"}, {"x-real-ip", "1.2.3.4"}]
      ...> |> RemoteIp.Headers.parse()
      [{1, 2, 3, 4}]
  """

  @spec parse(Plug.Conn.headers()) :: [:inet.ip_address()]

  def parse(headers) do
    RemoteIp.Debug.log :ips do
      Enum.flat_map(headers, fn {name, value} -> parse(name, value) end)
    end
  end

  defp parse("forwarded", value) do
    RemoteIp.Headers.Forwarded.parse(value)
  end

  defp parse(_generic, value) do
    RemoteIp.Headers.Generic.parse(value)
  end
end
