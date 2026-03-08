defmodule Orchid.OpenAIUsageTest do
  use ExUnit.Case, async: true

  alias Orchid.OpenAIUsage

  test "normalize_base_url appends backend-api for chatgpt host" do
    assert OpenAIUsage.normalize_base_url("https://chatgpt.com") ==
             "https://chatgpt.com/backend-api"

    assert OpenAIUsage.normalize_base_url("https://chatgpt.com/backend-api/") ==
             "https://chatgpt.com/backend-api"
  end

  test "parse_id_token extracts plan, email, user and account ids" do
    jwt =
      fake_jwt(%{
        "email" => "dev@example.com",
        "https://api.openai.com/auth" => %{
          "chatgpt_plan_type" => "pro",
          "chatgpt_user_id" => "user_123",
          "chatgpt_account_id" => "acct_456"
        }
      })

    assert OpenAIUsage.parse_id_token(jwt) == %{
             email: "dev@example.com",
             plan_type: "Pro",
             raw_plan_type: "pro",
             user_id: "user_123",
             account_id: "acct_456"
           }
  end

  test "snapshot_from_payload builds codex and additional limits" do
    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 42,
          "limit_window_seconds" => 300,
          "reset_at" => 1_700_000_000
        },
        "secondary_window" => %{
          "used_percent" => 81,
          "limit_window_seconds" => 604_800,
          "reset_at" => 1_700_600_000
        }
      },
      "credits" => %{
        "has_credits" => true,
        "unlimited" => false,
        "balance" => "38"
      },
      "additional_rate_limits" => [
        %{
          "metered_feature" => "codex_other",
          "limit_name" => "codex_other",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => 7,
              "limit_window_seconds" => 60,
              "reset_at" => 1_700_000_120
            }
          }
        }
      ]
    }

    auth_info = %{
      email: "dev@example.com",
      account_id: "acct_456",
      plan_type: "Pro",
      raw_plan_type: "pro",
      user_id: "user_123",
      base_url: "https://chatgpt.com/backend-api"
    }

    snapshot = OpenAIUsage.snapshot_from_payload(payload, auth_info)

    assert snapshot.account.email == "dev@example.com"
    assert snapshot.account.plan_type == "Plus"
    assert snapshot.credits.balance == "38"
    assert snapshot.primary_limit.limit_id == "codex"
    assert length(snapshot.limits) == 2

    assert Enum.at(snapshot.limits, 0).primary.window_minutes == 5
    assert Enum.at(snapshot.limits, 0).secondary.window_minutes == 10_080
    assert Enum.at(snapshot.limits, 1).limit_id == "codex_other"
    assert Enum.at(snapshot.limits, 1).primary.window_minutes == 1
  end

  defp fake_jwt(payload) do
    header = %{"alg" => "none", "typ" => "JWT"}

    [header, payload, %{"sig" => true}]
    |> Enum.map_join(".", fn part ->
      part
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
    end)
  end
end
