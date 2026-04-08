defmodule SymphonyElixir.Runtime.Registry do
  @moduledoc """
  Resolves runtime profiles to concrete adapter modules.

  Config-driven and stateless — reads from `Config.Schema` on each call
  so config reloads take effect immediately. Only add process state
  when runtime health tracking requires it.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.RuntimeProfile
  alias SymphonyElixir.Runtime.Profile

  @adapter_modules %{
    "direct" => SymphonyElixir.Runtime.DirectCodexAdapter,
    "acp" => SymphonyElixir.Runtime.ACPAdapter
  }

  @spec resolve_for_role(atom()) :: {:ok, Profile.t()} | {:error, term()}
  def resolve_for_role(role) when role in [:planner, :worker, :judge] do
    with {:ok, runtime_profile} <- Config.runtime_profile_for_role(role) do
      resolve_adapter(runtime_profile)
    end
  end

  @spec resolve_by_name(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def resolve_by_name(name) when is_binary(name) do
    with {:ok, settings} <- Config.settings(),
         {:ok, runtime_profile} <- Schema.runtime_profile(settings, name) do
      resolve_adapter(runtime_profile)
    end
  end

  @spec resolve_default() :: {:ok, Profile.t()} | {:error, term()}
  def resolve_default do
    with {:ok, settings} <- Config.settings() do
      profile = Schema.materialize_codex_default_profile(settings)
      resolve_adapter(profile)
    end
  end

  @spec list_profiles() :: {:ok, %{String.t() => Profile.t()}} | {:error, term()}
  def list_profiles do
    with {:ok, profiles} <- Config.runtime_profiles() do
      resolved =
        Map.new(profiles, fn {name, runtime_profile} ->
          case resolve_adapter(runtime_profile) do
            {:ok, profile} -> {name, profile}
            {:error, _} -> {name, nil}
          end
        end)
        |> Enum.reject(fn {_name, profile} -> is_nil(profile) end)
        |> Map.new()

      {:ok, resolved}
    end
  end

  @spec adapter_module_for(String.t()) :: {:ok, module()} | {:error, {:unknown_adapter, String.t()}}
  def adapter_module_for(adapter_type) when is_binary(adapter_type) do
    case Map.fetch(@adapter_modules, adapter_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_adapter, adapter_type}}
    end
  end

  defp resolve_adapter(%RuntimeProfile{adapter: adapter_type} = runtime_profile) do
    case adapter_module_for(adapter_type) do
      {:ok, module} -> {:ok, Profile.new(runtime_profile, module)}
      {:error, _} = error -> error
    end
  end
end
