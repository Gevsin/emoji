defmodule EmojiWeb.HomeLive do
  use EmojiWeb, :live_view
  alias Emoji.Predictions

  @preprompt "A TOK emoji of a "

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(form: to_form(%{"prompt" => ""}))
     |> assign(show_bg: false)
     |> stream(:my_predictions, [])
     |> stream(:predictions, Predictions.list_finished_predictions())
     |> stream(:recent_predictions, Predictions.list_firehose_predictions())}
  end

  def handle_event("thumbs-up", %{"id" => id}, socket) do
    prediction = Predictions.get_prediction!(id)

    {:ok, _prediction} =
      Predictions.update_prediction(prediction, %{
        score: prediction.score + 1,
        count_votes: prediction.count_votes + 1
      })

    {:noreply, socket |> put_flash(:info, "Thanks for your rating!")}
  end

  def handle_event("thumbs-down", %{"id" => id}, socket) do
    prediction = Predictions.get_prediction!(id)

    {:ok, _prediction} =
      Predictions.update_prediction(prediction, %{
        score: prediction.score - 1,
        count_votes: prediction.count_votes + 1
      })

    {:noreply, socket |> put_flash(:info, "Thanks for your rating!")}
  end

  def handle_event("toggle-bg", _, socket) do
    {:noreply, socket |> assign(show_bg: !socket.assigns.show_bg)}
  end

  def handle_event("validate", %{"prompt" => _prompt}, socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"prompt" => prompt}, socket) do
    styled_prompt =
      (@preprompt <> String.trim_trailing(String.downcase(prompt)))
      |> String.replace("emoji of a a ", "emoji of a ")
      |> String.replace("emoji of a an ", "emoji of an ")

    {:ok, prediction} = Predictions.create_prediction(%{prompt: styled_prompt})

    start_task(fn -> {:image_generated, prediction, gen_image(styled_prompt)} end)

    {:noreply,
     socket
     |> stream_insert(:my_predictions, prediction, at: 0)}
  end

  def handle_info({:image_generated, prediction, {:ok, r8_prediction}}, socket) do
    r2_url = save_r2("prediction-#{prediction.id}-emoji", r8_prediction.output |> List.first())

    {:ok, prediction} =
      Predictions.update_prediction(prediction, %{
        emoji_output: r2_url,
        uuid: r8_prediction.id
      })

    start_task(fn -> {:background_removed, prediction, remove_bg(prediction.emoji_output)} end)

    {:noreply,
     socket
     |> stream_insert(:my_predictions, prediction)
     |> put_flash(:info, "Image generated. Starting background removal")}
  end

  def handle_info({:background_removed, prediction, image}, socket) do
    r2_url = save_r2("prediction-#{prediction.id}-nobg", image)
    {:ok, prediction} = Predictions.update_prediction(prediction, %{no_bg_output: r2_url})

    {:noreply,
     socket
     |> stream_insert(:my_predictions, prediction)
     |> put_flash(:info, "Background successfully removed!")}
  end

  defp human_name(name) do
    dasherize(name)
  end

  defp dasherize(name) do
    name
    |> String.replace(@preprompt, "")
    |> String.replace("A TOK emoji of an ", "")
    |> String.split(" ")
    |> Enum.join("-")
    |> String.replace("--", "-")
  end

  defp remove_bg(url) do
    "cjwbw/rembg:fb8af171cfa1616ddcf1242c093f9c46bcada5ad4cf6f2fbe8b81b330ec5c003"
    |> Replicate.run(image: url)
  end

  defp gen_image(prompt) do
    model = Replicate.Models.get!("fofr/sdxl-emoji")

    version =
      Replicate.Models.get_version!(
        model,
        "fadf75f542463e8fd1e3d83a0775ad0f3a0fd2ca3f6bb5ad52a7639cdf8ba93f"
      )

    {:ok, prediction} =
      Replicate.Predictions.create(version, %{
        prompt: prompt,
        width: 768,
        height: 768,
        num_inference_steps: 30
      })

    Replicate.Predictions.wait(prediction)
  end

  defp start_task(fun) do
    pid = self()

    Task.start_link(fn ->
      result = fun.()
      send(pid, result)
    end)
  end

  def save_r2(name, image_url) do
    {:ok, resp} = :httpc.request(:get, {image_url, []}, [], body_format: :binary)
    {{_, 200, ~c"OK"}, _headers, image_binary} = resp

    file_name = "#{name}.png"
    bucket = System.get_env("BUCKET_NAME")

    %{status_code: 200} =
      ExAws.S3.put_object(bucket, file_name, image_binary)
      |> ExAws.request!()

    "#{System.get_env("CLOUDFLARE_PUBLIC_URL")}/#{file_name}"
  end
end
