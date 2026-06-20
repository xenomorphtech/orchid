defmodule Orchid.LLM do
  @moduledoc """
  Unified interface for LLM providers.

  Providers:
  - :cli - Claude CLI wrapper (uses claude command) - DEFAULT
  - :oauth - OAuth tokens from .claude_tokens.json (subscription)
  - :anthropic - Direct API calls (pay per token, needs ANTHROPIC_API_KEY)
  """

  alias Orchid.LLM.{Anthropic, OAuth, CLI, Codex, CodexHttp, Gemini, Cerebras, OpenRouter, Catalog}

  @doc """
  Send a chat request to the configured LLM provider.
  Returns {:ok, %{content: String.t(), tool_calls: list() | nil}}
  """
  def chat(config, context) do
    case resolve_provider(config) do
      :cli -> CLI.chat(config, context)
      :codex -> Codex.chat(config, context)
      :codex_http -> CodexHttp.chat(config, context)
      :oauth -> OAuth.chat(config, context)
      :anthropic -> Anthropic.chat(config, context)
      :gemini -> Gemini.chat(config, context)
      :cerebras -> Cerebras.chat(config, context)
      :openrouter -> OpenRouter.chat(config, context)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Send a streaming chat request.
  Callback receives text chunks as they arrive.
  """
  def chat_stream(config, context, callback) do
    case resolve_provider(config) do
      :cli -> CLI.chat_stream(config, context, callback)
      :codex -> Codex.chat_stream(config, context, callback)
      :codex_http -> CodexHttp.chat_stream(config, context, callback)
      :oauth -> OAuth.chat_stream(config, context, callback)
      :anthropic -> Anthropic.chat_stream(config, context, callback)
      :gemini -> Gemini.chat_stream(config, context, callback)
      :cerebras -> Cerebras.chat_stream(config, context, callback)
      :openrouter -> OpenRouter.chat_stream(config, context, callback)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Get available tools formatted for the LLM provider.
  """
  def format_tools(config, tools) do
    case resolve_provider(config) do
      :anthropic -> Anthropic.format_tools(tools)
      :gemini -> Gemini.format_tools(tools)
      :openrouter -> OpenRouter.format_tools(tools)
      _ -> tools
    end
  end

  defp resolve_provider(config) do
    Catalog.provider_for_model(config[:model]) || Catalog.normalize_provider(config[:provider]) ||
      :cli
  end
end
