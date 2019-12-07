defmodule Ash.Actions do
  # def run_create_action(resource, action, attributes, relationships, params) do
  #   case Ash.Data.create(resource, action, attributes, relationships, params) do
  #     {:ok, record} ->
  #       Ash.Data.side_load(record, Map.get(params, :side_load, []), resource)

  #     {:error, error} ->
  #       {:error, error}
  #   end
  # end

  # def run_update_action(%resource{} = record, action, attributes, relationships, params) do
  #   with {:ok, record} <- Ash.Data.update(record, action, attributes, relationships, params),
  #        {:ok, [record]} <-
  #          Ash.Data.side_load([record], Map.get(params, :side_load, []), resource) do
  #     {:ok, record}
  #   else
  #     {:error, error} -> {:error, error}
  #   end
  # end

  # def run_destroy_action(record, action, params) do
  #   Ash.Data.delete(record, action, params)
  # end

  def run_read_action(resource, action, api, params) do
    auth_context = %{
      resource: resource,
      action: action,
      params: params
    }

    user = Map.get(params, :user)
    auth? = Map.get(params, :authorize?, false)

    with {%{prediction: prediction} = instructions, per_check_data}
         when prediction != :unauthorized <-
           maybe_authorize_precheck(auth?, user, action.rules, auth_context),
         query <- Ash.DataLayer.resource_to_query(resource),
         {:ok, filter} <- Ash.Actions.Filter.process(resource, Map.get(params, :filter, %{})),
         {:ok, sort} <- Ash.Actions.Sort.process(resource, Map.get(params, :sort, [])),
         {:ok, filtered_query} <- Ash.DataLayer.filter(query, filter, resource),
         {:ok, sorted_query} <- Ash.DataLayer.sort(filtered_query, sort, resource),
         {:ok, paginator} <-
           Ash.Actions.Paginator.paginate(api, resource, action, sorted_query, params),
         {:ok, found} <- Ash.DataLayer.run_query(paginator.query, resource),
         {:ok, side_loaded_for_auth} <-
           Ash.Actions.SideLoader.side_load(
             resource,
             found,
             Map.get(instructions, :side_load, []),
             api,
             Map.take(params, [:authorize?, :user])
           ),
         :allow <-
           maybe_authorize(
             auth?,
             user,
             side_loaded_for_auth,
             action.rules,
             auth_context,
             per_check_data
           ),
         {:ok, side_loaded} <-
           Ash.Actions.SideLoader.side_load(
             resource,
             side_loaded_for_auth,
             Map.get(params, :side_load, []),
             api,
             Map.take(params, [:authorize?, :user])
           ) do
      {:ok, %{paginator | results: side_loaded}}
    else
      {:error, error} ->
        {:error, error}

      {%{prediction: :unauthorized}, _} ->
        # TODO: Nice errors here!
        {:error, :unauthorized}

      {:unauthorized, _data} ->
        # TODO: Nice errors here!
        {:error, :unauthorized}
    end
  end

  def run_create_action(resource, action, api, params) do
    auth_context = %{
      resource: resource,
      action: action,
      params: params
    }

    user = Map.get(params, :user)
    auth? = Map.get(params, :authorize?, false)

    # TODO: no instrutions relevant to creates right now?
    with {:ok, changeset, relationships} <- prepare_create_params(resource, params),
         {%{prediction: prediction}, per_check_data}
         when prediction != :unauthorized <-
           maybe_authorize_precheck(
             auth?,
             user,
             action.rules,
             Map.merge(auth_context, %{changeset: changeset, relationships: relationships})
           ),
         {:ok, created} <-
           Ash.DataLayer.create(resource, changeset, relationships),
         :allow <-
           maybe_authorize(
             auth?,
             user,
             [created],
             action.rules,
             auth_context,
             per_check_data
           ),
         {:ok, side_loaded} <-
           Ash.Actions.SideLoader.side_load(
             resource,
             created,
             Map.get(params, :side_load, []),
             api,
             Map.take(params, [:authorize?, :user])
           ) do
      {:ok, side_loaded}
    else
      %Ecto.Changeset{valid?: false} ->
        # TODO: Explain validation problems
        {:error, "invalid changes"}

      {:error, error} ->
        {:error, error}

      {%{prediction: :unauthorized}, _} ->
        # TODO: Nice errors here!
        {:error, :unauthorized}

      {:unauthorized, _data} ->
        # TODO: Nice errors here!
        {:error, :unauthorized}
    end
  end

  defp prepare_create_params(resource, params) do
    attributes = Map.get(params, :attributes, %{})
    relationships = Map.get(params, :relationships, %{})

    with {:ok, changeset} <- prepare_create_attributes(resource, attributes),
         {:ok, relationships} <- prepare_create_relationships(resource, relationships) do
      {:ok, changeset, relationships}
    else
      {:error, error} ->
        {:error, error}
    end
  end

  defp prepare_create_attributes(resource, attributes) do
    allowed_keys =
      resource
      |> Ash.attributes()
      |> Enum.map(& &1.name)

    resource
    |> struct()
    |> Ecto.Changeset.cast(Map.put_new(attributes, :id, Ecto.UUID.generate()), allowed_keys)
    |> case do
      %{valid?: true} = changeset ->
        {:ok, changeset}

      _error_changeset ->
        # TODO: Print the errors here.
        {:error, "invalid attributes"}
    end
  end

  defp prepare_create_relationships(resource, relationships) do
    relationships
    # Eventually we'll have to just copy changeset's logic
    # and/or use it directly (now that ecto is split up, maybe thats the way to do all of this?)
    |> Enum.reduce({%{}, []}, fn {key, value}, {changes, errors} ->
      case Ash.relationship(resource, key) do
        nil ->
          {changes, ["unknown attribute #{key}" | errors]}

        _attribute ->
          # TODO do actual value validation here
          {Map.put(changes, key, value), errors}
      end
    end)
    |> case do
      {changes, []} -> {:ok, changes}
      {_, errors} -> {:error, errors}
    end
  end

  defp maybe_authorize(false, _, _, _, _, _), do: :allow

  defp maybe_authorize(true, user, data, rules, auth_context, per_check_data) do
    Ash.Authorization.Authorizer.authorize(user, data, rules, auth_context, per_check_data)
  end

  defp maybe_authorize_precheck(false, _, _, _), do: {%{prediction: :allow}, []}

  defp maybe_authorize_precheck(true, user, rules, auth_context) do
    Ash.Authorization.Authorizer.authorize_precheck(user, rules, auth_context)
  end
end