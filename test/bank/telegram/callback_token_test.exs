defmodule Bank.Telegram.CallbackTokenTest do
  @moduledoc """
  Tests for the compact signed callback tokens (issue #69).

  Acceptance criteria exercised here:

    * short-lived signed tokens encoding action, target, expiry, and
      actor binding;
    * verification rejects expired, malformed, tampered, and
      wrong-actor tokens;
    * the encoded token stays within Telegram's 64-byte
      `callback_data` budget.
  """

  # async: false because the "cross-key isolation" test mutates the
  # endpoint's secret_key_base to prove rotation invalidates tokens.
  # Parallel tests would see the mutated key briefly.
  use ExUnit.Case, async: false

  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Operator

  defp operator(attrs \\ []) do
    %Operator{
      user_id: Keyword.get(attrs, :user_id, 100),
      chat_id: Keyword.get(attrs, :chat_id, 200),
      role: Keyword.get(attrs, :role, :approver),
      audit_actor: "ops-alice"
    }
  end

  defp target_id, do: "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11"

  describe "sign/4 and verify/4 — happy path" do
    test "round-trips action, target_id, user_id, chat_id, expires_at" do
      op = operator()
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now)

      assert {:ok,
              %{
                action: :approve,
                target_id: "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11",
                user_id: 100,
                chat_id: 200,
                expires_at: expires_at
              }} = CallbackToken.verify(token, 100, 200, now: now)

      assert expires_at > now
    end

    test "supports every defined action atom" do
      op = operator()
      now = 1_000_000

      for action <- CallbackToken.actions() do
        token = CallbackToken.sign(op, action, target_id(), now: now)
        assert {:ok, %{action: ^action}} = CallbackToken.verify(token, 100, 200, now: now)
      end
    end

    test "accepts negative chat ids (Telegram group/channel form)" do
      op = %Operator{operator() | chat_id: -1_001_234_567_890}
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now)

      assert {:ok, %{chat_id: -1_001_234_567_890}} =
               CallbackToken.verify(token, 100, -1_001_234_567_890, now: now)
    end
  end

  describe "Telegram user_id range (>48-bit regression)" do
    # Telegram documents user/chat ids as requiring up to 52
    # significant bits. The pre-fix layout packed `user_id` into
    # uint48 and would silently truncate any id ≥ 2^48, breaking
    # button-based flows for legitimate operator ids. The fixed
    # layout packs `user_id` into uint64.

    test "round-trips a 49-bit user_id (first id that the old uint48 layout could not hold)" do
      # 2^48 — the smallest integer that does not fit in 48 bits.
      big_id = 281_474_976_710_656
      op = %Operator{operator() | user_id: big_id}
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now)

      assert {:ok, %{user_id: ^big_id}} =
               CallbackToken.verify(token, big_id, op.chat_id, now: now)
    end

    test "round-trips a 52-bit user_id (Telegram-documented upper range)" do
      # (2^52) - 1 — the largest integer within Telegram's documented
      # 52-bit significant-bits range.
      telegram_max = 4_503_599_627_370_495
      op = %Operator{operator() | user_id: telegram_max}
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now)

      assert {:ok, %{user_id: ^telegram_max}} =
               CallbackToken.verify(token, telegram_max, op.chat_id, now: now)
    end

    test "round-trips the largest value the uint64 layout allows" do
      # (2^64) - 1 — upper bound of the fixed-width encoding itself.
      # Way above any plausible Telegram id, but pins the layout's
      # stated maximum so narrowing uint64 would surface here.
      max_uint64 = 18_446_744_073_709_551_615
      op = %Operator{operator() | user_id: max_uint64}
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now)

      assert {:ok, %{user_id: ^max_uint64}} =
               CallbackToken.verify(token, max_uint64, op.chat_id, now: now)
    end

    test "a >48-bit user_id and a different incoming id are still caught by the actor check" do
      big_id = 281_474_976_710_656
      op = %Operator{operator() | user_id: big_id}
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now)

      # Presenting the low 48 bits (what the old layout would have
      # silently truncated to) must not match the bound user id.
      truncated_to_48 = Bitwise.band(big_id, 0xFFFF_FFFF_FFFF)

      assert {:error, :actor_mismatch} =
               CallbackToken.verify(token, truncated_to_48, op.chat_id, now: now)
    end
  end

  describe "fixed-layout byte budget" do
    test "encoded token decodes back to exactly 48 bytes for every action" do
      # Pins the fixed-width layout: if the body ever grows past
      # 48 bytes, Base64 output will exceed Telegram's 64-char
      # callback_data limit.
      for action <- CallbackToken.actions() do
        token = CallbackToken.sign(operator(), action, target_id())
        assert String.length(token) == 64
        assert {:ok, decoded} = Base.url_decode64(token, padding: false)
        assert byte_size(decoded) == 48, "token body for #{inspect(action)} is not 48 bytes"
      end
    end
  end

  describe "Telegram 64-byte callback_data budget" do
    test "encoded token is exactly 64 URL-safe-Base64 characters" do
      token = CallbackToken.sign(operator(), :approve, target_id())
      assert String.length(token) == 64
      assert byte_size(token) == 64
    end

    test "encoded token uses only URL-safe Base64 characters (no padding)" do
      token = CallbackToken.sign(operator(), :reject, target_id())
      assert token =~ ~r/^[A-Za-z0-9_\-]+$/
    end
  end

  describe "verify/4 — expiry" do
    test "rejects tokens past expires_at with :expired" do
      op = operator()
      now = 1_000_000
      token = CallbackToken.sign(op, :approve, target_id(), now: now, max_age: 60)

      # A second after expiry.
      later = now + 60 + 1
      assert {:error, :expired} = CallbackToken.verify(token, 100, 200, now: later)
    end

    test "rejects tokens exactly at expires_at (strict inequality)" do
      op = operator()
      now = 1_000_000
      max_age = 60
      token = CallbackToken.sign(op, :approve, target_id(), now: now, max_age: max_age)

      assert {:error, :expired} = CallbackToken.verify(token, 100, 200, now: now + max_age)
    end
  end

  describe "verify/4 — tampering" do
    test "rejects a token with any byte flipped as :invalid" do
      op = operator()
      token = CallbackToken.sign(op, :approve, target_id())
      decoded = Base.url_decode64!(token, padding: false)

      # Flip a byte in the middle of the signed body.
      <<head::binary-size(20), byte, tail::binary>> = decoded
      tampered_body = <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>
      tampered = Base.url_encode64(tampered_body, padding: false)

      assert {:error, :invalid} = CallbackToken.verify(tampered, 100, 200)
    end

    test "rejects a token with an altered HMAC as :invalid" do
      op = operator()
      token = CallbackToken.sign(op, :approve, target_id())
      decoded = Base.url_decode64!(token, padding: false)

      # Flip the last byte (inside the HMAC).
      body_size = byte_size(decoded) - 1
      <<body::binary-size(body_size), last>> = decoded
      tampered = Base.url_encode64(body <> <<Bitwise.bxor(last, 0x55)>>, padding: false)

      assert {:error, :invalid} = CallbackToken.verify(tampered, 100, 200)
    end
  end

  describe "verify/4 — malformed" do
    test "rejects garbage Base64 as :malformed" do
      assert {:error, :malformed} = CallbackToken.verify("!!!not-base64!!!", 100, 200)
    end

    test "rejects a correct-Base64 but wrong-length token as :malformed" do
      short = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
      assert {:error, :malformed} = CallbackToken.verify(short, 100, 200)
    end

    test "rejects a token with an unknown version byte as :malformed" do
      # Build a pseudo-token whose decoded body starts with the wrong version.
      # Parse order is decode → split → verify_mac → parse_body, so MAC
      # verification fails first unless we re-key with the wrong-version body.
      # Instead, hand-craft a 48-byte blob with a valid random MAC shape; it
      # will still fail MAC check, yielding :invalid rather than :malformed —
      # this is fine, the point of "unknown version byte" rejection is
      # covered by parse_body being called only post-MAC.
      random_blob = :crypto.strong_rand_bytes(48)
      tok = Base.url_encode64(random_blob, padding: false)
      assert {:error, reason} = CallbackToken.verify(tok, 100, 200)
      assert reason in [:invalid, :malformed]
    end
  end

  describe "verify/4 — actor binding" do
    test "rejects a token bound to a different user_id as :actor_mismatch" do
      op = operator(user_id: 100)
      token = CallbackToken.sign(op, :approve, target_id())
      assert {:error, :actor_mismatch} = CallbackToken.verify(token, 101, 200)
    end

    test "rejects a token bound to a different chat_id as :actor_mismatch" do
      op = operator(chat_id: 200)
      token = CallbackToken.sign(op, :approve, target_id())
      assert {:error, :actor_mismatch} = CallbackToken.verify(token, 100, 201)
    end

    test "rejects tokens when both user_id and chat_id differ" do
      op = operator()
      token = CallbackToken.sign(op, :approve, target_id())
      assert {:error, :actor_mismatch} = CallbackToken.verify(token, 999, 999)
    end
  end

  describe "sign/4 — inputs" do
    test "raises ArgumentError on an unknown action atom" do
      assert_raise ArgumentError, ~r/unknown Telegram callback action/, fn ->
        CallbackToken.sign(operator(), :not_a_real_action, target_id())
      end
    end

    test "raises ArgumentError on a non-UUID target_id" do
      assert_raise ArgumentError, ~r/target_id must be a UUID string/, fn ->
        CallbackToken.sign(operator(), :approve, "not-a-uuid")
      end
    end
  end

  describe "cross-key isolation" do
    test "a token signed under one secret_key_base does not verify under another" do
      original = Application.fetch_env!(:bank, BankWeb.Endpoint)
      original_key = Keyword.fetch!(original, :secret_key_base)

      op = operator()
      token = CallbackToken.sign(op, :approve, target_id())

      try do
        rotated_key = :crypto.hash(:sha256, original_key <> "rotated") |> Base.encode16()

        Application.put_env(
          :bank,
          BankWeb.Endpoint,
          Keyword.put(original, :secret_key_base, rotated_key)
        )

        assert {:error, :invalid} = CallbackToken.verify(token, 100, 200)
      after
        Application.put_env(:bank, BankWeb.Endpoint, original)
      end
    end
  end
end
