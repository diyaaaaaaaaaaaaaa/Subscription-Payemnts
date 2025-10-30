module payment_stream_addr::payment_stream {
    use std::signer;
    use std::error;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_std::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};

    // Error codes
    const E_NOT_INITIALIZED: u64 = 1;
    const E_STREAM_NOT_FOUND: u64 = 2;
    const E_NOT_AUTHORIZED: u64 = 3;
    const E_INVALID_DURATION: u64 = 4;
    const E_INVALID_AMOUNT: u64 = 5;
    const E_STREAM_ALREADY_CANCELLED: u64 = 6;
    const E_NO_FUNDS_AVAILABLE: u64 = 7;
    const E_STREAM_NOT_STARTED: u64 = 8;
    const E_INSUFFICIENT_BALANCE: u64 = 9;

    // Stream status
    const STREAM_ACTIVE: u8 = 1;
    const STREAM_CANCELLED: u8 = 2;
    const STREAM_COMPLETED: u8 = 3;

    /// Represents a single payment stream
    struct PaymentStream has store {
        sender: address,
        recipient: address,
        total_amount: u64,
        withdrawn_amount: u64,
        start_time: u64,
        end_time: u64,
        status: u8,
        deposited_coins: Coin<AptosCoin>,
    }

    /// Global storage for all payment streams
    struct StreamRegistry has key {
        streams: Table<u64, PaymentStream>,
        next_stream_id: u64,
        stream_created_events: EventHandle<StreamCreatedEvent>,
        stream_withdrawn_events: EventHandle<StreamWithdrawnEvent>,
        stream_cancelled_events: EventHandle<StreamCancelledEvent>,
    }

    /// Event emitted when a new stream is created
    struct StreamCreatedEvent has drop, store {
        stream_id: u64,
        sender: address,
        recipient: address,
        total_amount: u64,
        start_time: u64,
        end_time: u64,
    }

    /// Event emitted when funds are withdrawn
    struct StreamWithdrawnEvent has drop, store {
        stream_id: u64,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    /// Event emitted when a stream is cancelled
    struct StreamCancelledEvent has drop, store {
        stream_id: u64,
        sender: address,
        refunded_amount: u64,
        timestamp: u64,
    }

    /// Initialize the module (call once on deployment)
    public entry fun initialize(account: &signer) {
        let account_addr = signer::address_of(account);
        
        if (!exists<StreamRegistry>(account_addr)) {
            move_to(account, StreamRegistry {
                streams: table::new(),
                next_stream_id: 0,
                stream_created_events: account::new_event_handle<StreamCreatedEvent>(account),
                stream_withdrawn_events: account::new_event_handle<StreamWithdrawnEvent>(account),
                stream_cancelled_events: account::new_event_handle<StreamCancelledEvent>(account),
            });
        };
    }

    /// Create a new payment stream
    /// @param sender - The account creating and funding the stream
    /// @param recipient - The address receiving the streamed payments
    /// @param amount - Total amount to be streamed (in octas for APT)
    /// @param duration_seconds - Duration of the stream in seconds
    public entry fun create_stream(
        sender: &signer,
        recipient: address,
        amount: u64,
        duration_seconds: u64,
    ) acquires StreamRegistry {
        let sender_addr = signer::address_of(sender);
        
        // Validation
        assert!(duration_seconds > 0, error::invalid_argument(E_INVALID_DURATION));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(coin::balance<AptosCoin>(sender_addr) >= amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Get registry
        let registry = borrow_global_mut<StreamRegistry>(@payment_stream_addr);
        let stream_id = registry.next_stream_id;
        
        // Calculate times
        let current_time = timestamp::now_seconds();
        let end_time = current_time + duration_seconds;

        // Withdraw coins from sender
        let coins = coin::withdraw<AptosCoin>(sender, amount);

        // Create stream
        let stream = PaymentStream {
            sender: sender_addr,
            recipient,
            total_amount: amount,
            withdrawn_amount: 0,
            start_time: current_time,
            end_time,
            status: STREAM_ACTIVE,
            deposited_coins: coins,
        };

        // Store stream
        table::add(&mut registry.streams, stream_id, stream);
        registry.next_stream_id = stream_id + 1;

        // Emit event
        event::emit_event(&mut registry.stream_created_events, StreamCreatedEvent {
            stream_id,
            sender: sender_addr,
            recipient,
            total_amount: amount,
            start_time: current_time,
            end_time,
        });
    }

    /// Calculate the amount available for withdrawal at current time
    fun calculate_vested_amount(stream: &PaymentStream): u64 {
        let current_time = timestamp::now_seconds();
        
        // If stream hasn't started yet
        if (current_time < stream.start_time) {
            return 0
        };

        // If stream has ended, all funds are vested
        if (current_time >= stream.end_time) {
            return stream.total_amount - stream.withdrawn_amount
        };

        // Calculate vested amount based on time elapsed
        let elapsed = current_time - stream.start_time;
        let duration = stream.end_time - stream.start_time;
        let vested_total = (stream.total_amount * elapsed) / duration;
        
        // Return amount available for withdrawal
        if (vested_total > stream.withdrawn_amount) {
            vested_total - stream.withdrawn_amount
        } else {
            0
        }
    }

    /// Withdraw available funds from a stream
    /// @param recipient - The account withdrawing (must be the stream recipient)
    /// @param stream_id - ID of the stream to withdraw from
    public entry fun withdraw(
        recipient: &signer,
        stream_id: u64,
    ) acquires StreamRegistry {
        let recipient_addr = signer::address_of(recipient);
        let registry = borrow_global_mut<StreamRegistry>(@payment_stream_addr);
        
        assert!(table::contains(&registry.streams, stream_id), error::not_found(E_STREAM_NOT_FOUND));
        
        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        
        // Validation
        assert!(stream.recipient == recipient_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(stream.status == STREAM_ACTIVE, error::invalid_state(E_STREAM_ALREADY_CANCELLED));
        
        // Calculate available amount
        let available = calculate_vested_amount(stream);
        assert!(available > 0, error::invalid_state(E_NO_FUNDS_AVAILABLE));

        // Extract coins and deposit to recipient
        let coins_to_withdraw = coin::extract(&mut stream.deposited_coins, available);
        coin::deposit(recipient_addr, coins_to_withdraw);

        // Update stream
        stream.withdrawn_amount = stream.withdrawn_amount + available;

        // Mark as completed if fully withdrawn
        if (stream.withdrawn_amount == stream.total_amount) {
            stream.status = STREAM_COMPLETED;
        };

        // Emit event
        event::emit_event(&mut registry.stream_withdrawn_events, StreamWithdrawnEvent {
            stream_id,
            recipient: recipient_addr,
            amount: available,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Cancel a stream and refund unvested funds to sender
    /// @param sender - The account cancelling (must be the stream creator)
    /// @param stream_id - ID of the stream to cancel
    public entry fun cancel_stream(
        sender: &signer,
        stream_id: u64,
    ) acquires StreamRegistry {
        let sender_addr = signer::address_of(sender);
        let registry = borrow_global_mut<StreamRegistry>(@payment_stream_addr);
        
        assert!(table::contains(&registry.streams, stream_id), error::not_found(E_STREAM_NOT_FOUND));
        
        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        
        // Validation
        assert!(stream.sender == sender_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(stream.status == STREAM_ACTIVE, error::invalid_state(E_STREAM_ALREADY_CANCELLED));

        // Calculate vested and unvested amounts
        let vested = calculate_vested_amount(stream);
        let remaining_balance = coin::value(&stream.deposited_coins);
        let refund_amount = remaining_balance - vested;

        // If there's vested amount, send to recipient
        if (vested > 0) {
            let vested_coins = coin::extract(&mut stream.deposited_coins, vested);
            coin::deposit(stream.recipient, vested_coins);
            stream.withdrawn_amount = stream.withdrawn_amount + vested;
        };

        // Refund unvested to sender
        if (refund_amount > 0) {
            let refund_coins = coin::extract(&mut stream.deposited_coins, refund_amount);
            coin::deposit(sender_addr, refund_coins);
        };

        // Mark as cancelled
        stream.status = STREAM_CANCELLED;

        // Emit event
        event::emit_event(&mut registry.stream_cancelled_events, StreamCancelledEvent {
            stream_id,
            sender: sender_addr,
            refunded_amount: refund_amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ==================== View Functions ====================

    #[view]
    /// Get stream details
    public fun get_stream(stream_id: u64): (address, address, u64, u64, u64, u64, u8) acquires StreamRegistry {
        let registry = borrow_global<StreamRegistry>(@payment_stream_addr);
        assert!(table::contains(&registry.streams, stream_id), error::not_found(E_STREAM_NOT_FOUND));
        
        let stream = table::borrow(&registry.streams, stream_id);
        (
            stream.sender,
            stream.recipient,
            stream.total_amount,
            stream.withdrawn_amount,
            stream.start_time,
            stream.end_time,
            stream.status
        )
    }

    #[view]
    /// Get available amount to withdraw for a stream
    public fun get_withdrawable_amount(stream_id: u64): u64 acquires StreamRegistry {
        let registry = borrow_global<StreamRegistry>(@payment_stream_addr);
        assert!(table::contains(&registry.streams, stream_id), error::not_found(E_STREAM_NOT_FOUND));
        
        let stream = table::borrow(&registry.streams, stream_id);
        calculate_vested_amount(stream)
    }

    #[view]
    /// Get total number of streams created
    public fun get_total_streams(): u64 acquires StreamRegistry {
        let registry = borrow_global<StreamRegistry>(@payment_stream_addr);
        registry.next_stream_id
    }
}
