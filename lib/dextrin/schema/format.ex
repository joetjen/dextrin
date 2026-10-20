defmodule Dextrin.Schema.Format do
  @moduledoc """
  The formats a refine's `format:` names (DXN.md §4.2a, Jan,
  2026-10-20): a closed set, each checked the same way in every
  implementation. A format DXN has a tag for is read by that tag's
  reader; every other one by a grammar written as a regular expression
  that PCRE, JavaScript (with the `u` flag) and PHP all read alike.
  """

  alias Dextrin.{Ip, Temporal, Uuid}

  # ---- the grammars' parts, RFC 3986 and RFC 3987 ---------------------------

  @label "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
  @hostname "^#{@label}(?:\\.#{@label})*$"
  @u_label "[\\p{L}\\p{N}](?:[\\p{L}\\p{N}\\p{M}-]{0,61}[\\p{L}\\p{N}\\p{M}])?"
  @idn_hostname "^#{@u_label}(?:\\.#{@u_label})*$"

  @atext "[\\-A-Za-z0-9!#$%&'*+/=?^_`{|}~]"
  # Past ASCII: every character an IRI or an internationalised address
  # adds, written so PCRE, JavaScript and PHP read it alike.
  @beyond "[^\\x00-\\x7F]"
  @quoted ~S'"(?:[\x20\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E])*"'
  @local "^(?:#{@atext}+(?:\\.#{@atext}+)*|#{@quoted})$"
  @idn_atext "(?:#{@atext}|#{@beyond})"
  @idn_local "^(?:#{@idn_atext}+(?:\\.#{@idn_atext}+)*|#{@quoted})$"

  # `extra` is what an IRI adds to the characters a URI leaves
  # unencoded: every character past ASCII; nothing for a URI.
  defp uri_grammar(extra, absolute?) do
    pct = "%[0-9A-Fa-f]{2}#{extra}"
    u = "\\-A-Za-z0-9._~!$&'()*+,;="
    pchar = "(?:[#{u}:@]|#{pct})"
    nc = "(?:[#{u}@]|#{pct})"
    userinfo = "(?:(?:[#{u}:]|#{pct})*@)?"
    host = "(?:\\[[^\\]]*\\]|(?:[#{u}]|#{pct})*)"
    authority = "#{userinfo}#{host}(?::[0-9]*)?"
    abempty = "(?:/#{pchar}*)*"
    absolute = "/(?:#{pchar}+(?:/#{pchar}*)*)?"
    rootless = "#{pchar}+(?:/#{pchar}*)*"
    noscheme = "#{nc}+(?:/#{pchar}*)*"
    tail = "(?:\\?(?:#{pchar}|[/?])*)?(?:#(?:#{pchar}|[/?])*)?"

    if absolute?,
      do:
        "^[A-Za-z][A-Za-z0-9+.-]*:(?://#{authority}#{abempty}|#{absolute}|#{rootless}|)#{tail}$",
      else: "^(?://#{authority}#{abempty}|#{absolute}|#{noscheme}|)#{tail}$"
  end

  @uri_extra ""
  @iri_extra "|#{@beyond}"

  @varspec "(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})(?:\\.?(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2}))*(?::[1-9][0-9]{0,3}|\\*)?"
  @uri_template "^(?:[^\\x00-\\x20\"'%<>\\\\^`{|}\\x7F]|%[0-9A-Fa-f]{2}|\\{[+#./;?&=,!@|]?#{@varspec}(?:,#{@varspec})*\\})*$"

  @json_pointer "^(?:/(?:[^~/]|~[01])*)*$"
  @relative_json_pointer "^(?:0|[1-9][0-9]*)(?:#|(?:/(?:[^~/]|~[01])*)*)$"

  @semver "^(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)" <>
            "(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?" <>
            "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$"

  @mac "^[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(?:\\1[0-9A-Fa-f]{2}){4}(?:(?:\\1[0-9A-Fa-f]{2}){2})?$"
  @port "^(?:0|[1-9][0-9]{0,4})$"

  @grammars %{
    "hostname" => @hostname,
    "idn-hostname" => @idn_hostname,
    "uri-template" => @uri_template,
    "json-pointer" => @json_pointer,
    "relative-json-pointer" => @relative_json_pointer,
    "semver" => @semver,
    "mac" => @mac
  }

  @names ~w(date time datetime local-datetime duration uuid ipv4 ipv6 hostname idn-hostname
            email idn-email uri uri-reference iri iri-reference uri-template json-pointer
            relative-json-pointer semver mac host-port)

  @doc "Every format's name, sorted."
  @spec names() :: [String.t()]
  def names, do: Enum.sort(@names)

  @doc """
  Whether `text` is in the format named `name`.

      iex> Dextrin.Schema.Format.valid?("semver", "1.2.3-rc.1")
      true
      iex> Dextrin.Schema.Format.valid?("hostname", "-a.example")
      false
  """
  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(name, text) when is_binary(text), do: String.valid?(text) and check(name, text)

  defp check("date", text), do: match?({:ok, _}, Temporal.parse_date(text))
  defp check("time", text), do: match?({:ok, _}, Temporal.parse_time(text))
  defp check("datetime", text), do: match?({:ok, _}, Temporal.parse_datetime(text))
  defp check("local-datetime", text), do: match?({:ok, _}, Temporal.parse_local(text))
  defp check("duration", text), do: match?({:ok, _}, Temporal.parse_duration(text))
  defp check("uuid", text), do: match?({:ok, _}, Uuid.parse(text))
  defp check("ipv4", text), do: address?(text, 4)
  defp check("ipv6", text), do: address?(text, 6)

  # RFC 1123's labels, the whole at most 253 characters.
  defp check(name, text) when name in ["hostname", "idn-hostname"],
    do: String.length(text) <= 253 and matches?(name, text)

  defp check("email", text), do: email?(text, @local, "hostname")
  defp check("idn-email", text), do: email?(text, @idn_local, "idn-hostname")
  defp check("uri", text), do: uri?(text, @uri_extra, true)

  defp check("uri-reference", text),
    do: uri?(text, @uri_extra, true) or uri?(text, @uri_extra, false)

  defp check("iri", text), do: uri?(text, @iri_extra, true)

  defp check("iri-reference", text),
    do: uri?(text, @iri_extra, true) or uri?(text, @iri_extra, false)

  defp check("host-port", text) do
    case :binary.matches(text, ":") do
      [] ->
        false

      matches ->
        {at, 1} = List.last(matches)
        host = binary_part(text, 0, at)
        port = binary_part(text, at + 1, byte_size(text) - at - 1)

        host_port_host?(host) and regex(@port) |> Regex.match?(port) and
          String.to_integer(port) <= 65_535
    end
  end

  defp check(name, text), do: matches?(name, text)

  defp matches?(name, text), do: Regex.match?(regex(Map.fetch!(@grammars, name)), text)

  # The grammars compiled once, on first use, held in :persistent_term.
  defp regex(source) do
    key = {__MODULE__, source}

    case :persistent_term.get(key, nil) do
      nil ->
        re = Regex.compile!(source, "u")
        :persistent_term.put(key, re)
        re

      re ->
        re
    end
  end

  defp address?(text, version) do
    case Ip.parse(text) do
      {:ok, %Ip{prefix: nil} = ip} -> Ip.version(ip) == version
      _ -> false
    end
  end

  # A local part, `@`, then a hostname or an address literal: `[IPv4]`
  # or `[IPv6:...]` (RFC 5321 §4.1.3); the local part at most 64 bytes.
  defp email?(text, local, hostname) do
    case :binary.matches(text, "@") do
      [] ->
        false

      matches ->
        {at, 1} = List.last(matches)
        name = binary_part(text, 0, at)
        domain = binary_part(text, at + 1, byte_size(text) - at - 1)

        byte_size(name) <= 64 and Regex.match?(regex(local), name) and
          (check(hostname, domain) or address_literal?(domain))
    end
  end

  defp address_literal?("[IPv6:" <> rest), do: bracketed?(rest, 6)
  defp address_literal?("[" <> rest), do: bracketed?(rest, 4)
  defp address_literal?(_domain), do: false

  defp bracketed?(rest, version) do
    String.ends_with?(rest, "]") and address?(String.slice(rest, 0..-2//1), version)
  end

  defp host_port_host?("[" <> _ = host),
    do: address_literal?(String.replace_prefix(host, "[", "[IPv6:"))

  defp host_port_host?(host), do: check("hostname", host) or address?(host, 4)

  # The grammar, then any `[...]` host an IPv6 address or RFC 3986's
  # IPvFuture.
  defp uri?(text, extra, absolute?) do
    Regex.match?(regex(uri_grammar(extra, absolute?)), text) and
      Enum.all?(Regex.scan(regex("//[^/?#]*?\\[([^\\]]*)\\]"), text), fn [_, inside] ->
        address?(inside, 6) or
          Regex.match?(regex("^v[0-9A-Fa-f]+\\.[A-Za-z0-9._~!$&'()*+,;=:-]+$"), inside)
      end)
  end
end
