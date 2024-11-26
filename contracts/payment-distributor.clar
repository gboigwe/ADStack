;; payment-distributor.clar
;; Advanced payment distribution and reward system for the advertising platform
;; Version: 2.0.0

;; ============================================
;; Constants and Error Codes
;; ============================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u401))
(define-constant ERR_INVALID_PARAMS (err u400))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_INSUFFICIENT_FUNDS (err u405))
(define-constant ERR_PAYMENT_FAILED (err u406))
(define-constant ERR_INVALID_AMOUNT (err u407))
(define-constant ERR_ALREADY_CLAIMED (err u408))
(define-constant ERR_NOT_ELIGIBLE (err u409))
(define-constant ERR_DISTRIBUTION_LOCKED (err u410))

;; ============================================
;; Data Variables
;; ============================================

(define-data-var platform-fee-percent uint u2)    
(define-data-var min-payout-amount uint u1000000) 
(define-data-var total-distributed uint u0)        
(define-data-var distribution-nonce uint u0)       
(define-data-var treasury-balance uint u0)         
(define-data-var pool-counter uint u0)            

;; ============================================
;; Data Maps
;; ============================================

(define-map distributions 
    { id: uint }
    {
        recipient: principal,
        amount: uint,
        campaign-id: uint,
        block-height: uint,
        status: (string-ascii 20),
        fee-amount: uint,
        proof: (buff 32)
    }
)

(define-map publisher-accounts
    { publisher: principal }
    {
        balance: uint,
        total-earned: uint,
        last-payout-height: uint,
        payout-address: (optional principal),
        payment-schedule: (string-ascii 10),
        auto-payout: bool,
        min-payout: uint
    }
)

(define-map revenue-pools
    { id: uint }
    {
        total-amount: uint,
        participants: uint,
        share-price: uint,
        start-height: uint,
        end-height: uint,
        status: (string-ascii 20),
        distribution-type: (string-ascii 20)
    }
)

(define-map reward-points
    { publisher: principal }
    {
        points: uint,
        tier: (string-ascii 10),
        multiplier: uint,
        last-updated: uint,
        history: (list 10 {
            action: (string-ascii 20),
            amount: uint,
            block-height: uint
        })
    }
)

(define-map payment-claims
    { id: (buff 32) }
    {
        publisher: principal,
        amount: uint,
        status: (string-ascii 20),
        expiry-height: uint,
        claimed: bool
    }
)

;; ============================================
;; Private Functions
;; ============================================

(define-private (calculate-platform-fee (amount uint))
    (/ (* amount (var-get platform-fee-percent)) u100)
)

(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (generate-distribution-id)
    (let 
        ((current-nonce (var-get distribution-nonce)))
        (var-set distribution-nonce (+ current-nonce u1))
        current-nonce
    )
)

(define-private (validate-amount (amount uint))
    (and 
        (> amount u0)
        (>= amount (var-get min-payout-amount))
    )
)

(define-private (create-reward-history-entry (amount uint))
    {
        action: "earn",
        amount: amount,
        block-height: block-height
    }
)

(define-private (determine-reward-tier (points uint))
    (if (>= points u1000000)
        "platinum"
        (if (>= points u500000)
            "gold"
            (if (>= points u100000)
                "silver"
                "bronze"
            )
        )
    )
)

(define-private (get-tier-multiplier (tier (string-ascii 10)))
    (if (is-eq tier "platinum")
        u20
        (if (is-eq tier "gold")
            u15
            (if (is-eq tier "silver")
                u12
                u10
            )
        )
    )
)

(define-private (update-publisher-balance (publisher principal) (amount uint))
    (let 
        ((account (unwrap! (map-get? publisher-accounts { publisher: publisher }) false)))
        
            (map-set publisher-accounts
                { publisher: publisher }
                (merge account {
                    balance: (+ (get balance account) amount),
                    total-earned: (+ (get total-earned account) amount)
                })
            )
        
    )
)

(define-private (calculate-reward-points (amount uint))
    (/ amount u1000000)
)

(define-private (update-reward-points (publisher principal) (points uint))
    (let 
        ((history-entry (create-reward-history-entry points)))
        (match (map-get? reward-points { publisher: publisher })
            existing-data 
            (ok 
                (map-set reward-points
                    { publisher: publisher }
                    {
                        points: (+ (get points existing-data) points),
                        tier: (determine-reward-tier (+ (get points existing-data) points)),
                        multiplier: (get-tier-multiplier (determine-reward-tier (+ (get points existing-data) points))),
                        last-updated: block-height,
                        history: (unwrap! 
                            (as-max-len? 
                                (append 
                                    (list history-entry) 
                                    (get history existing-data)
                                ) 
                                u10
                            )
                            (list history-entry)
                        )
                    }
                )
            )
            (ok 
                (map-set reward-points
                    { publisher: publisher }
                    {
                        points: points,
                        tier: (determine-reward-tier points),
                        multiplier: (get-tier-multiplier (determine-reward-tier points)),
                        last-updated: block-height,
                        history: (list history-entry)
                    }
                )
            )
        )
    )
)

;; ============================================
;; Public Functions
;; ============================================

(define-public (process-payment
    (recipient principal)
    (amount uint)
    (campaign-id uint)
    (proof (buff 32)))
    
    (begin
        (asserts! (validate-amount amount) ERR_INVALID_PARAMS)
        
        (let
            ((distribution-id (generate-distribution-id))
             (fee-amount (calculate-platform-fee amount)))
            
            (var-set treasury-balance (+ (var-get treasury-balance) fee-amount))
            
            (try! 
                (map-set distributions
                    { id: distribution-id }
                    {
                        recipient: recipient,
                        amount: amount,
                        campaign-id: campaign-id,
                        block-height: block-height,
                        status: "completed",
                        fee-amount: fee-amount,
                        proof: proof
                    }
                )
            )
            
            (try! (update-publisher-balance recipient (- amount fee-amount)))
            (try! (update-reward-points recipient (calculate-reward-points amount)))
            
            (var-set total-distributed (+ (var-get total-distributed) amount))
            
            (ok distribution-id)
        )
    )
)

(define-public (claim-payment (claim-id (buff 32)))
    (let 
        ((claim (unwrap! (map-get? payment-claims { id: claim-id }) ERR_NOT_FOUND)))
        (begin
            (asserts! (is-eq tx-sender (get publisher claim)) ERR_NOT_AUTHORIZED)
            (asserts! (not (get claimed claim)) ERR_ALREADY_CLAIMED)
            (asserts! (< block-height (get expiry-height claim)) ERR_NOT_ELIGIBLE)
            
            (try! 
                (as-contract 
                    (stx-transfer? (get amount claim) tx-sender (get publisher claim))
                )
            )
            
            (map-set payment-claims
                { id: claim-id }
                (merge claim { 
                    claimed: true,
                    status: "paid"
                })
            )
            
            (ok true)
        )
    )
)

(define-public (create-revenue-pool 
    (initial-amount uint)
    (duration uint)
    (distribution-type (string-ascii 20)))
    
    (begin
        (asserts! (> initial-amount u0) ERR_INVALID_PARAMS)
        (asserts! (> duration u0) ERR_INVALID_PARAMS)
        
        (let
            ((pool-id (+ (var-get pool-counter) u1)))
            
            (try! (stx-transfer? initial-amount tx-sender (as-contract tx-sender)))
            
            (try! 
                (map-set revenue-pools
                    { id: pool-id }
                    {
                        total-amount: initial-amount,
                        participants: u0,
                        share-price: u0,
                        start-height: block-height,
                        end-height: (+ block-height duration),
                        status: "active",
                        distribution-type: distribution-type
                    }
                )
            )
            
            (var-set pool-counter pool-id)
            
            (ok pool-id)
        )
    )
)

;; ============================================
;; Admin Functions
;; ============================================

(define-public (set-platform-fee (new-fee uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (<= new-fee u10) ERR_INVALID_PARAMS)
        (ok (var-set platform-fee-percent new-fee))
    )
)

(define-public (withdraw-treasury (amount uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (<= amount (var-get treasury-balance)) ERR_INSUFFICIENT_FUNDS)
        
        (try! (as-contract (stx-transfer? amount tx-sender CONTRACT_OWNER)))
        (ok (var-set treasury-balance (- (var-get treasury-balance) amount)))
    )
)

;; ============================================
;; Read-Only Functions
;; ============================================

(define-read-only (get-distribution (distribution-id uint))
    (ok (unwrap! (map-get? distributions { id: distribution-id }) ERR_NOT_FOUND))
)

(define-read-only (get-publisher-account (publisher principal))
    (ok (unwrap! (map-get? publisher-accounts { publisher: publisher }) ERR_NOT_FOUND))
)

(define-read-only (get-revenue-pool (pool-id uint))
    (ok (unwrap! (map-get? revenue-pools { id: pool-id }) ERR_NOT_FOUND))
)

(define-read-only (get-publisher-rewards (publisher principal))
    (ok (unwrap! (map-get? reward-points { publisher: publisher }) ERR_NOT_FOUND))
)
