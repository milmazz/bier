defmodule Bier.ConformanceAssertions do
  @moduledoc """
  Interprets a conformance case's `expect` block against a normalized response
  map `%{status:, headers:, body:}` (header keys pre-downcased).
  """
  import ExUnit.Assertions

  @doc "Assert every key of `expect` holds for `resp`. Unknown keys raise."
  def assert_expect(resp, expect) when is_map(expect) do
    Enum.each(expect, fn {key, val} -> check(key, val, resp) end)
  end

  defp check("status", expected, resp) do
    assert resp.status == expected,
           "expected status #{expected}, got #{resp.status}"
  end

  defp check("headers", map, resp) when is_map(map) do
    Enum.each(map, fn {name, value} ->
      actual = Map.get(resp.headers, String.downcase(name))

      assert actual == value,
             "header #{name}: expected #{inspect(value)}, got #{inspect(actual)}"
    end)
  end

  defp check("headers_present", names, resp) when is_list(names) do
    Enum.each(names, fn name ->
      assert Map.has_key?(resp.headers, String.downcase(name)),
             "expected header #{name} to be present"
    end)
  end

  defp check("headers_absent", names, resp) when is_list(names) do
    Enum.each(names, fn name ->
      refute Map.has_key?(resp.headers, String.downcase(name)),
             "expected header #{name} to be absent"
    end)
  end

  # body_json is an alias of body_exact: both assert deep JSON equality.
  # Empty/nil expected value means the body itself must be empty.
  defp check(key, expected, resp)
       when key in ["body_exact", "body_json"] and expected in [nil, ""] do
    assert resp.body == "",
           "#{key} expected empty body, got: #{inspect(resp.body)}"
  end

  defp check(key, expected, resp) when key in ["body_exact", "body_json"] do
    actual = decode_json(resp.body)

    assert actual == expected,
           "#{key} mismatch:\n  expected: #{inspect(expected)}\n  got:      #{inspect(actual)}"
  end

  defp check("body_contains", expected, resp) do
    needles = List.wrap(expected)

    Enum.each(needles, fn needle ->
      assert is_binary(needle),
             "body_contains needle must be a string, got #{inspect(needle)}"

      assert String.contains?(resp.body, needle),
             "body did not contain #{inspect(needle)}"
    end)
  end

  defp check("body_raw", expected, resp) do
    assert resp.body == expected,
           "body_raw mismatch:\n  expected: #{inspect(expected)}\n  got:      #{inspect(resp.body)}"
  end

  defp check("headers_match", map, resp) when is_map(map) do
    Enum.each(map, fn {name, regex_string} ->
      value = Map.get(resp.headers, String.downcase(name), "")
      regex = Regex.compile!(regex_string)

      assert Regex.match?(regex, value),
             "header #{name}: value #{inspect(value)} did not match regex #{inspect(regex_string)}"
    end)
  end

  defp check("headers_no_blank", true, resp) do
    Enum.each(resp.headers, fn {name, value} ->
      refute String.trim(value) == "",
             "header #{name} has a blank value"
    end)
  end

  defp check("headers_absent_in_value", map, resp) when is_map(map) do
    Enum.each(map, fn {name, substrings} ->
      value = Map.get(resp.headers, String.downcase(name), "")

      Enum.each(substrings, fn substr ->
        refute String.contains?(value, substr),
               "header #{name}: value #{inspect(value)} must not contain #{inspect(substr)}"
      end)
    end)
  end

  defp check(key, _val, _resp) do
    raise "unsupported assertion key: #{inspect(key)}"
  end

  defp decode_json(body) do
    Bier.json_library().decode!(body)
  rescue
    _ -> flunk("response body was not valid JSON: #{inspect(body)}")
  end
end
