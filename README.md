
# 💧 Payment Stream Protocol on Aptos

### A decentralized time-based payment system for continuous fund transfers built with Move on the Aptos blockchain.

<img width="2825" height="1294" alt="image" src="https://github.com/user-attachments/assets/861e202b-a206-4a35-83f4-ea74c61893f7" />
<img width="2808" height="1286" alt="image" src="https://github.com/user-attachments/assets/865146b9-03c1-4ceb-8aa4-c6b6ceece9e8" />



---

## 🧩 Overview

The **Payment Stream Protocol** enables users to **create, withdraw, and cancel continuous payment streams** in Aptos Coin (APT).
It allows funds to be distributed **linearly over time**, ensuring recipients receive payments in a predictable and transparent manner.

This is especially useful for:

* Payroll automation
* Subscriptions or recurring payments
* Grants and vesting schedules
* Time-based donations or community rewards

---

## 🚀 Features

* ⏱ **Time-based Streaming:** Funds are unlocked linearly between start and end timestamps.
* 🔐 **On-chain Fund Locking:** Coins are securely held in the contract during the stream duration.
* 💸 **Partial Withdrawals:** Recipients can withdraw vested funds anytime.
* ❌ **Cancelable Streams:** Senders can cancel streams and get unvested funds refunded.
* 🧾 **Event Tracking:** Every create, withdraw, and cancel action emits on-chain events for transparency.
* 📊 **View Functions:** Query stream status, details, and available balances.

---

## 🏗️ Module Structure

**Module Path:**

```
payment_stream_addr::payment_stream
```

**Key Components:**

| Component              | Description                                                                              |
| ---------------------- | ---------------------------------------------------------------------------------------- |
| `PaymentStream`        | Represents an individual payment stream with sender, recipient, timing, and balance info |
| `StreamRegistry`       | Global storage maintaining all active and past streams                                   |
| `StreamCreatedEvent`   | Emitted when a stream is created                                                         |
| `StreamWithdrawnEvent` | Emitted when a recipient withdraws funds                                                 |
| `StreamCancelledEvent` | Emitted when a stream is canceled                                                        |

---

## ⚙️ Functions

### 🏁 `initialize(account: &signer)`

Initializes the module for the deploying account.
Creates the global `StreamRegistry` if it doesn’t already exist.

> ⚠️ Must be called **once** during deployment.

---

### 💧 `create_stream(sender: &signer, recipient: address, amount: u64, duration_seconds: u64)`

Creates a new payment stream.

**Validations:**

* Duration and amount must be > 0
* Sender must have sufficient APT balance

**Flow:**

1. Withdraws `amount` of APT from the sender
2. Locks it in a new `PaymentStream`
3. Emits a `StreamCreatedEvent`

**Emitted Event:** `StreamCreatedEvent`
**Error Codes:**
`E_INVALID_DURATION`, `E_INVALID_AMOUNT`, `E_INSUFFICIENT_BALANCE`

---

### 💸 `withdraw(recipient: &signer, stream_id: u64)`

Allows the recipient to withdraw vested funds.

**Flow:**

1. Calculates available (vested) amount
2. Transfers that amount to the recipient
3. Updates withdrawn total
4. Emits `StreamWithdrawnEvent`

**Emitted Event:** `StreamWithdrawnEvent`
**Error Codes:**
`E_STREAM_NOT_FOUND`, `E_NOT_AUTHORIZED`, `E_STREAM_ALREADY_CANCELLED`, `E_NO_FUNDS_AVAILABLE`

---

### 🚫 `cancel_stream(sender: &signer, stream_id: u64)`

Allows the sender to cancel an ongoing stream.

**Flow:**

1. Calculates vested (earned) vs unvested (refund) funds
2. Transfers vested funds to recipient
3. Refunds unvested funds to sender
4. Marks stream as cancelled
5. Emits `StreamCancelledEvent`

**Emitted Event:** `StreamCancelledEvent`
**Error Codes:**
`E_STREAM_NOT_FOUND`, `E_NOT_AUTHORIZED`, `E_STREAM_ALREADY_CANCELLED`

---

### 🔍 View Functions

| Function                                  | Description                                    | Returns                                                                             |
| ----------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------- |
| `get_stream(stream_id: u64)`              | Fetches all details of a stream                | `(sender, recipient, total_amount, withdrawn_amount, start_time, end_time, status)` |
| `get_withdrawable_amount(stream_id: u64)` | Calculates currently available (vested) amount | `u64`                                                                               |
| `get_total_streams()`                     | Returns total number of streams created        | `u64`                                                                               |

---

## 📜 Event Summary

| Event                    | Trigger            | Data                                                                         |
| ------------------------ | ------------------ | ---------------------------------------------------------------------------- |
| **StreamCreatedEvent**   | On stream creation | `stream_id`, `sender`, `recipient`, `total_amount`, `start_time`, `end_time` |
| **StreamWithdrawnEvent** | On withdrawal      | `stream_id`, `recipient`, `amount`, `timestamp`                              |
| **StreamCancelledEvent** | On cancellation    | `stream_id`, `sender`, `refunded_amount`, `timestamp`                        |

---

## ⚠️ Error Codes

| Code | Name                         | Description                    |
| ---- | ---------------------------- | ------------------------------ |
| `1`  | `E_NOT_INITIALIZED`          | Registry not initialized       |
| `2`  | `E_STREAM_NOT_FOUND`         | Stream ID doesn’t exist        |
| `3`  | `E_NOT_AUTHORIZED`           | Caller not authorized          |
| `4`  | `E_INVALID_DURATION`         | Invalid duration value         |
| `5`  | `E_INVALID_AMOUNT`           | Invalid amount value           |
| `6`  | `E_STREAM_ALREADY_CANCELLED` | Stream already cancelled       |
| `7`  | `E_NO_FUNDS_AVAILABLE`       | No vested funds to withdraw    |
| `8`  | `E_STREAM_NOT_STARTED`       | Stream not yet started         |
| `9`  | `E_INSUFFICIENT_BALANCE`     | Sender doesn’t have enough APT |

---

## 🧠 How Vesting Works

Let:

* `total_amount` = 100 APT
* `duration` = 100 seconds
* `start_time` = 0
* `end_time` = 100

If current time = 40s → vested = `40/100 * 100 = 40 APT`.
Recipient can withdraw up to 40 APT, and the rest remains locked until more time passes.

---

## 🧰 Example Workflow

1. **Initialize**

   ```bash
   aptos move run --function-id 'payment_stream_addr::payment_stream::initialize' --account <deployer>
   ```

2. **Create Stream**

   ```bash
   aptos move run --function-id 'payment_stream_addr::payment_stream::create_stream' \
     --args address:<recipient_addr> u64:100000000 u64:3600
   ```

   ⏳ Streams 1 APT over 1 hour.

3. **Withdraw**

   ```bash
   aptos move run --function-id 'payment_stream_addr::payment_stream::withdraw' \
     --args u64:<stream_id>
   ```

4. **Cancel Stream**

   ```bash
   aptos move run --function-id 'payment_stream_addr::payment_stream::cancel_stream' \
     --args u64:<stream_id>
   ```

---

## 🧾 Transaction Reference

**Deployed Transaction Hash:**

```
0x24664e1cea9cbe63ec77d189aafa4a0646ac7ef52ed84a2d0b77909a0c54eec9
```

---

## 📦 Future Improvements

* Support for **custom coins** (beyond AptosCoin)
* Stream pausing and resuming
* Batch stream creation for organizations
* Frontend dashboard for visualization

---

## 🛠️ Tech Stack

* **Blockchain:** Aptos
* **Language:** Move
* **Frameworks:** `aptos_framework`, `aptos_std`
* **Coin Type:** `AptosCoin`

---
