defmodule EmojiWeb.HomeLive do
  use EmojiWeb, :live_view
  alias Emoji.Predictions

  @preprompt "A TOK emoji of a "

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(form: to_form(%{"prompt" => ""}))
     |> assign(local_user_id: nil)
     |> assign(remove_bg: true)
     |> stream(:my_predictions, [])
     |> stream(:featured_predictions, Predictions.list_featured_predictions())}
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

  def handle_event("assign-user-id", %{"userId" => user_id}, socket) do
    {:noreply, socket |> assign(local_user_id: user_id)}
  end

  def handle_event("save", %{"prompt" => prompt}, socket) do
    styled_prompt =
      (@preprompt <> String.trim_trailing(String.downcase(prompt)))
      |> String.replace("emoji of a a ", "emoji of a ")
      |> String.replace("emoji of a an ", "emoji of an ")

    {:ok, prediction} =
      Predictions.create_prediction(%{
        prompt: styled_prompt,
        local_user_id: socket.assigns.local_user_id
      })

    start_task(fn -> {:image_generated, prediction, gen_image(styled_prompt)} end)

    {:noreply,
     socket
     |> stream_insert(:my_predictions, prediction, at: 0)}
  end

  def handle_info({:image_generated, prediction, {:ok, %{output: nil} = r8_prediction}}, socket) do
    {:ok, _prediction} =
      Predictions.update_prediction(prediction, %{
        emoji_output:
          "https://github.com/replicate/zoo/assets/14149230/39c124db-a793-4ca9-a9b4-706fe18984ad",
        uuid: r8_prediction.id
      })

    {:noreply,
     socket
     |> put_flash(:error, "Uh oh, image generation failed. Likely NSFW input. Try again!")}
  end

  def handle_info({:image_generated, prediction, {:ok, r8_prediction}}, socket) do
    # r2_url = save_r2("prediction-#{prediction.id}-emoji", r8_prediction.output |> List.first())

    {:ok, prediction} =
      Predictions.update_prediction(prediction, %{
        emoji_output: r8_prediction.output |> List.first(),
        uuid: r8_prediction.id
      })

    start_task(fn -> {:background_removed, prediction, remove_bg(prediction.emoji_output)} end)

    {:noreply,
     socket
     |> stream_insert(:my_predictions, prediction)
     |> put_flash(:info, "Image generated. Starting background removal")}
  end

  def handle_info({:background_removed, prediction, image}, socket) do
    # r2_url = save_r2("prediction-#{prediction.id}-nobg", image)
    send_telegram_message(prediction.prompt, image)

    {:ok, prediction} = Predictions.update_prediction(prediction, %{no_bg_output: image})

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
        "4d2c2e5e40a5cad182e5729b49a08247c22a5954ae20356592caaada42dc8985"
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

  def send_telegram_message(prompt, image) do
    token = System.fetch_env!("TELEGRAM_BOT_TOKEN")
    chat_id = System.fetch_env!("TELEGRAM_CHAT_ID")

    url = "https://api.telegram.org/bot#{token}/sendMessage"
    headers = ["Content-Type": "application/json"]
    body = Jason.encode!(%{chat_id: chat_id, text: "prompt: #{prompt}, image: #{image}"})

    HTTPoison.post(url, body, headers)
  end
end
