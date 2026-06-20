defmodule Orchid.LLM.Catalog do
  @moduledoc false

  @providers [
    %{id: :cli, label: "CLI", contexts: [:template]},
    %{id: :codex, label: "Codex", contexts: [:template]},
    %{id: :codex_http, label: "Codex HTTP", contexts: [:template]},
    %{id: :oauth, label: "API", contexts: [:template]},
    %{id: :gemini, label: "Gemini", contexts: [:template]},
    %{id: :cerebras, label: "Cerebras", contexts: [:template]},
    %{id: :openrouter, label: "OpenRouter", contexts: [:template]},
    %{id: :anthropic, label: "Anthropic", contexts: []}
  ]

  @models [
    %{
      id: :opus,
      label: "Opus",
      providers: %{cli: "opus", oauth: "claude-opus-4-5-20251101"},
      aliases: ["opus-4.6", "claude-opus-4.6"],
      contexts: [:template, :decomp]
    },
    %{
      id: :sonnet,
      label: "Sonnet",
      providers: %{cli: "claude-sonnet-4-6", oauth: "claude-sonnet-4-6"},
      aliases: ["claude-sonnet-4-20250514"],
      contexts: [:template, :decomp]
    },
    %{
      id: :haiku,
      label: "Haiku",
      providers: %{cli: "haiku", oauth: "claude-haiku-4-5-20251001"},
      contexts: [:template, :decomp]
    },
    %{
      id: :gpt54,
      label: "GPT 5.4",
      providers: %{codex: "gpt-5.4", codex_http: "gpt-5.4"},
      contexts: [:template, :decomp]
    },
    %{
      id: :gpt53,
      label: "GPT 5.3",
      providers: %{codex: "gpt-5.3-codex", codex_http: "gpt-5.3-codex"},
      contexts: [:template, :decomp]
    },
    %{
      id: :gemini_pro,
      label: "Gemini Pro",
      providers: %{gemini: "gemini-2.5-pro"},
      contexts: [:template]
    },
    %{
      id: :gemini_flash,
      label: "Gemini Flash",
      providers: %{gemini: "gemini-2.5-flash"},
      contexts: [:template]
    },
    %{
      id: :gemini_flash_image,
      label: "Gemini Flash Image",
      providers: %{gemini: "gemini-2.5-flash-image"},
      contexts: [:template]
    },
    %{
      id: :gemini_3_flash,
      label: "Gemini 3 Flash",
      providers: %{gemini: "gemini-3-flash-preview"},
      contexts: [:template]
    },
    %{
      id: :gemini_3_pro,
      label: "Gemini 3 Pro",
      providers: %{gemini: "gemini-3-pro-preview"},
      contexts: [:decomp]
    },
    %{
      id: :llama_3_1_8b,
      label: "Llama 3.1 8B",
      providers: %{cerebras: "llama3.1-8b"},
      contexts: [:template]
    },
    %{
      id: :llama_3_3_70b,
      label: "Llama 3.3 70B",
      providers: %{cerebras: "llama-3.3-70b"},
      contexts: [:template]
    },
    %{
      id: :gpt_oss_120b,
      label: "GPT OSS 120B",
      providers: %{cerebras: "gpt-oss-120b"},
      contexts: [:template]
    },
    %{
      id: :qwen_3_32b,
      label: "Qwen 3 32B",
      providers: %{cerebras: "qwen-3-32b"},
      contexts: [:template]
    },
    %{
      id: :qwen_3_235b,
      label: "Qwen 3 235B",
      providers: %{cerebras: "qwen-3-235b-a22b-instruct-2507"},
      contexts: [:template]
    },
    %{
      id: :zai_glm_4_7,
      label: "Z.ai GLM 4.7",
      providers: %{cerebras: "zai-glm-4.7"},
      contexts: [:template]
    },
    %{
      id: :minimax_m2_5,
      label: "MiniMax M2.5",
      providers: %{openrouter: "minimax/minimax-m2.5"},
      contexts: [:template, :decomp]
    },
    %{
      id: :glm_5,
      label: "GLM-5",
      providers: %{openrouter: "z-ai/glm-5"},
      contexts: [:template, :decomp]
    },
    %{
      id: :kimi_k2_5,
      label: "Kimi K2.5",
      providers: %{openrouter: "moonshotai/kimi-k2.5"},
      contexts: [:decomp]
    },
    %{
      id: :nex_n2_pro,
      label: "Nex N2 Pro (free)",
      providers: %{openrouter: "nex-agi/nex-n2-pro:free"},
      aliases: ["nex-n2-pro", "nex-agi/nex-n2-pro", "nex-agi/nex-n2-pro:free"],
      contexts: [:template, :decomp]
    }
  ]

  @provider_defaults %{
    oauth: :sonnet,
    gemini: :gemini_pro,
    cerebras: :llama_3_3_70b,
    openrouter: :nex_n2_pro
  }

  @providers_by_id Map.new(@providers, &{&1.id, &1})
  @models_by_id Map.new(@models, &{&1.id, &1})

  def providers(opts \\ []) do
    context = Keyword.get(opts, :context)

    Enum.filter(@providers, fn provider ->
      is_nil(context) or context in provider.contexts
    end)
  end

  def models(opts \\ []) do
    context = Keyword.get(opts, :context)
    provider = normalize_provider(Keyword.get(opts, :provider))

    Enum.filter(@models, fn model ->
      (is_nil(context) or context in model.contexts) and
        (is_nil(provider) or Map.has_key?(model.providers, provider))
    end)
  end

  def model_map(provider) do
    provider = normalize_provider(provider)

    models(provider: provider)
    |> Map.new(fn model -> {model.id, model.providers[provider]} end)
  end

  def default_model(provider) do
    provider
    |> normalize_provider()
    |> then(&Map.get(@provider_defaults, &1))
  end

  def provider_for_model(model) do
    case model(model) do
      %{providers: providers} when map_size(providers) == 1 ->
        providers
        |> Map.keys()
        |> hd()

      _ ->
        nil
    end
  end

  def resolve_model(model, provider) do
    provider = normalize_provider(provider)

    case normalize_model(model) do
      nil ->
        case default_model(provider) do
          nil -> nil
          default -> resolve_model(default, provider)
        end

      model_id when is_atom(model_id) ->
        case model(model_id) do
          %{providers: providers} ->
            cond do
              provider && Map.has_key?(providers, provider) ->
                providers[provider]

              map_size(providers) == 1 ->
                providers |> Map.values() |> hd()

              is_binary(model) ->
                String.trim(model)

              true ->
                Atom.to_string(model_id)
            end

          _ ->
            Atom.to_string(model_id)
        end

      model_name when is_binary(model_name) ->
        String.trim(model_name)
    end
  end

  def model(model) do
    model
    |> normalize_model()
    |> then(&Map.get(@models_by_id, &1))
  end

  def provider(provider) do
    provider
    |> normalize_provider()
    |> then(&Map.get(@providers_by_id, &1))
  end

  def normalize_model(nil), do: nil

  def normalize_model(model) when is_atom(model) do
    if Map.has_key?(@models_by_id, model) do
      model
    else
      case normalize_model(Atom.to_string(model)) do
        normalized when is_atom(normalized) -> normalized
        _ -> model
      end
    end
  end

  def normalize_model(model) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      trimmed == "" ->
        nil

      true ->
        Enum.find_value(@models, trimmed, fn entry ->
          known_names =
            [Atom.to_string(entry.id)]
            |> Kernel.++(entry[:aliases] || [])
            |> Kernel.++(Map.values(entry.providers))

          if trimmed in known_names, do: entry.id
        end)
    end
  end

  def normalize_provider(nil), do: nil

  def normalize_provider(provider) when is_atom(provider) do
    if Map.has_key?(@providers_by_id, provider) do
      provider
    else
      case normalize_provider(Atom.to_string(provider)) do
        normalized when is_atom(normalized) -> normalized
        _ -> provider
      end
    end
  end

  def normalize_provider(provider) when is_binary(provider) do
    trimmed = String.trim(provider)

    cond do
      trimmed == "" ->
        nil

      true ->
        Enum.find_value(@providers, trimmed, fn entry ->
          if trimmed == Atom.to_string(entry.id), do: entry.id
        end)
    end
  end

  def model_label(model) do
    case model(model) do
      %{label: label} ->
        label

      _ when is_atom(model) ->
        Atom.to_string(model)

      _ when is_binary(model) ->
        String.trim(model)

      _ ->
        nil
    end
  end

  def provider_label(provider) do
    case provider(provider) do
      %{label: label} ->
        label

      _ when is_atom(provider) ->
        Atom.to_string(provider)

      _ when is_binary(provider) ->
        String.trim(provider)

      _ ->
        nil
    end
  end
end
