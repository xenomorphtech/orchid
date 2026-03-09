defmodule Orchid.LLM.CatalogTest do
  use ExUnit.Case, async: true

  alias Orchid.LLM.Catalog

  test "normalizes known model aliases and external names" do
    assert Catalog.normalize_model("gpt-5.4") == :gpt54
    assert Catalog.normalize_model("gpt-5.3-codex") == :gpt53
    assert Catalog.normalize_model("claude-opus-4.6") == :opus
  end

  test "resolves provider specific model names from one catalog" do
    assert Catalog.resolve_model(:gpt54, :codex) == "gpt-5.4"
    assert Catalog.resolve_model(:sonnet, :cli) == "claude-sonnet-4-6"
    assert Catalog.resolve_model(:sonnet, :oauth) == "claude-sonnet-4-6"
    assert Catalog.resolve_model(nil, :gemini) == "gemini-2.5-pro"
  end

  test "infers providers only for single-provider models" do
    assert Catalog.provider_for_model(:gpt54) == :codex
    assert Catalog.provider_for_model(:gemini_pro) == :gemini
    assert Catalog.provider_for_model(:sonnet) == nil
  end
end
