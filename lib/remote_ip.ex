defmodule RemoteIp do
  use RemoteIp.Debug

  @behaviour Plug

  @moduledoc """
  A plug to overwrite the `Plug.Conn`'s `remote_ip` based on request headers.

  To use, add the `RemoteIp` plug to your app's plug pipeline:

  ```elixir
  defmodule MyApp do
    use Plug.Builder

    plug RemoteIp
  end
  ```

  Keep in mind the order of plugs in your pipeline and place `RemoteIp` as
  early as possible. For example, if you were to add `RemoteIp` *after* [the
  Plug Router](https://github.com/elixir-lang/plug#the-plug-router), your route
  action's logic would be executed *before* the `remote_ip` actually gets
  modified - not very useful!

  There are 3 options that can be passed in:

  * `:headers` - A list of strings naming the `req_headers` to use when
    deriving the `remote_ip`. Order does not matter. Defaults to `~w[forwarded
    x-forwarded-for x-client-ip x-real-ip]`.

  * `:proxies` - A list of strings in
    [CIDR](https://en.wikipedia.org/wiki/CIDR) notation specifying the IPs of
    known proxies. Defaults to `[]`.

      [Loopback](https://en.wikipedia.org/wiki/Loopback) and
      [private](https://en.wikipedia.org/wiki/Private_network) IPs are always
      appended to this list:

      * 127.0.0.0/8
      * ::1/128
      * fc00::/7
      * 10.0.0.0/8
      * 172.16.0.0/12
      * 192.168.0.0/16

      Since these IPs are internal, they often are not the actual client
      address in production, so we add them by default. To override this
      behavior, whitelist known client IPs using the `:clients` option.

  * `:clients` - A list of strings in
    [CIDR](https://en.wikipedia.org/wiki/CIDR) notation specifying the IPs of
    known clients. Defaults to `[]`.

      An IP in any of the ranges listed here will never be considered a proxy.
      This takes precedence over the `:proxies` option, including
      loopback/private addresses. Any IP that is **not** covered by `:clients`
      or `:proxies` is assumed to be a client IP.

  For example, suppose you know:
  * you are behind proxies in the 1.2.x.x block
  * the proxies use the `X-Foo`, `X-Bar`, and `X-Baz` headers
  * but the IP 1.2.3.4 is actually a client, not one of the proxies

  Then you could say

  ```elixir
  defmodule MyApp do
    use Plug.Builder

    plug RemoteIp,
         headers: ~w[x-foo x-bar x-baz],
         proxies: ~w[1.2.0.0/16],
         clients: ~w[1.2.3.4/32]
  end
  ```

  Note that, due to limitations in the
  [inet_cidr](https://github.com/Cobenian/inet_cidr) library used to parse
  them, `:proxies` and `:clients` **must** be written in full CIDR notation,
  even if specifying just a single IP. So instead of `"127.0.0.1"` and
  `"a:b::c:d"`, you would use `"127.0.0.1/32"` and `"a:b::c:d/128"`.

  For more details, refer to the
  [README](https://github.com/ajvondrak/remote_ip/blob/master/README.md) on
  GitHub.
  """

  @impl true

  def init(opts) do
    RemoteIp.Options.pack(opts)
  end

  @impl true

  def call(conn, opts) do
    RemoteIp.Debug.log :call, [conn] do
      ip = ip_from(conn.req_headers, opts) || conn.remote_ip
      add_metadata(ip)
      %{conn | remote_ip: ip}
    end
  end

  @doc """
  Standalone function to extract the remote IP from a list of headers.

  It's possible to get a subset of headers without access to a full `Plug.Conn`
  struct. For instance, when [using Phoenix
  sockets](https://hexdocs.pm/phoenix/Phoenix.Endpoint.html), your socket's
  `connect/3` callback may only be receiving `:x_headers` in the
  `connect_info`. Such situations make it inconvenient to use `RemoteIp`
  outside of a plug pipeline.

  Therefore, this function will fetch the remote IP from a plain list of header
  key-value pairs (just as you'd have in the `req_headers` of a `Plug.Conn`).
  You may optionally specify the same options as if you were using `RemoteIp`
  as a plug: they'll be processed by `RemoteIp.init/1` each time you call this
  function.

  If a remote IP cannot be parsed from the given headers (e.g., if the list is
  empty), this function will return `nil`.

  ## Examples

      iex> RemoteIp.from([{"x-forwarded-for", "1.2.3.4"}])
      {1, 2, 3, 4}

      iex> [{"x-foo", "1.2.3.4"}, {"x-bar", "2.3.4.5"}]
      ...> |> RemoteIp.from(headers: ~w[x-foo])
      {1, 2, 3, 4}

      iex> [{"x-foo", "1.2.3.4"}, {"x-bar", "2.3.4.5"}]
      ...> |> RemoteIp.from(headers: ~w[x-bar])
      {2, 3, 4, 5}

      iex> [{"x-foo", "1.2.3.4"}, {"x-bar", "2.3.4.5"}]
      ...> |> RemoteIp.from(headers: ~w[x-baz])
      nil
  """

  @spec from(Plug.Conn.headers(), keyword()) :: :inet.ip_address() | nil

  def from(headers, opts \\ []) do
    RemoteIp.Debug.log :from do
      ip_from(headers, init(opts))
    end
  end

  defp add_metadata(remote_ip) do
    case :inet.ntoa(remote_ip) do
      {:error, _} -> :ok
      ip -> Logger.metadata(remote_ip: to_string(ip))
    end
  end

  defp ip_from(headers, opts) do
    opts = RemoteIp.Options.unpack(opts)
    client_from(ips_from(headers, opts), opts)
  end

  defp ips_from(headers, opts) do
    RemoteIp.Headers.parse(headers, opts[:headers])
  end

  defp client_from(ips, opts) do
    Enum.reverse(ips) |> Enum.find(&client?(&1, opts))
  end

  defp client?(ip, opts) do
    known_client?(ip, opts) || (!known_proxy?(ip, opts) && !reserved?(ip))
  end

  defp known_client?(ip, opts) do
    RemoteIp.Debug.log :known_client, [ip] do
      opts[:clients] |> contains?(ip)
    end
  end

  defp known_proxy?(ip, opts) do
    RemoteIp.Debug.log :known_proxy, [ip] do
      opts[:proxies] |> contains?(ip)
    end
  end

  # https://en.wikipedia.org/wiki/Loopback
  # https://en.wikipedia.org/wiki/Private_network
  # https://en.wikipedia.org/wiki/Reserved_IP_addresses
  @reserved ~w[
    127.0.0.0/8
    ::1/128
    fc00::/7
    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
  ] |> Enum.map(&InetCidr.parse/1)

  defp reserved?(ip) do
    RemoteIp.Debug.log :reserved, [ip] do
      @reserved |> contains?(ip)
    end
  end

  defp contains?(cidrs, ip) do
    Enum.any?(cidrs, &InetCidr.contains?(&1, ip))
  end
end
