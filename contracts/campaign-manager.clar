;; Contract Name: campaign-manager.clar
;; Description: Handles the creation and management of advertising campaigns
;; Author :Gbolahan Akande

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-amount (err u101))
(define-constant err-campaign-not-found (err u102))
(define-constant err-campaign-expired (err u103))
(define-constant err-insufficient-balance (err u104))

;; Data variables
(define-data-var min-campaign-amount uint u100000) ;; Minimum STX amount for campaign creation

;; Campaign status enumeration
(define-data-var campaign-status (string-ascii 20) "active")

;; Data maps
(define-map Campaigns
    { campaign-id: uint }
    {
        advertiser: principal,
        budget: uint,
        remaining-budget: uint,
        cost-per-view: uint,
        start-height: uint,
        end-height: uint,
        status: (string-ascii 20),
        target-views: uint,
        current-views: uint
    }
)

(define-map AdvertiserStats
    { advertiser: principal }
    {
        total-campaigns: uint,
        total-spent: uint,
        active-campaigns: uint
    }
)

;; Private functions
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner)
)

(define-private (update-advertiser-stats (advertiser principal) (amount uint))
    (match (map-get? AdvertiserStats { advertiser: advertiser })
        existing-stats 
        (map-set AdvertiserStats
            { advertiser: advertiser }
            {
                total-campaigns: (+ (get total-campaigns existing-stats) u1),
                total-spent: (+ (get total-spent existing-stats) amount),
                active-campaigns: (+ (get active-campaigns existing-stats) u1)
            }
        )
        (map-set AdvertiserStats
            { advertiser: advertiser }
            {
                total-campaigns: u1,
                total-spent: amount,
                active-campaigns: u1
            }
        )
    )
)

;; Public functions

;; Create a new advertising campaign
(define-public (create-campaign 
    (budget uint) 
    (cost-per-view uint)
    (duration uint)
    (target-views uint))
    (let
        (
            (campaign-id (+ (var-get campaign-counter) u1))
            (start-block block-height)
            (end-block (+ block-height duration))
        )
        (asserts! (>= budget (var-get min-campaign-amount)) err-invalid-amount)
        (asserts! (>= budget (* cost-per-view target-views)) err-insufficient-balance)
        
        ;; Transfer STX from advertiser to contract
        (try! (stx-transfer? budget tx-sender (as-contract tx-sender)))
        
        ;; Create campaign record
        (map-set Campaigns
            { campaign-id: campaign-id }
            {
                advertiser: tx-sender,
                budget: budget,
                remaining-budget: budget,
                cost-per-view: cost-per-view,
                start-height: start-block,
                end-height: end-block,
                status: "active",
                target-views: target-views,
                current-views: u0
            }
        )
        
        ;; Update advertiser stats
        (update-advertiser-stats tx-sender budget)
        
        ;; Increment campaign counter
        (var-set campaign-counter campaign-id)
        (ok campaign-id)
    )
)

;; Get campaign details
(define-read-only (get-campaign-details (campaign-id uint))
    (match (map-get? Campaigns { campaign-id: campaign-id })
        campaign (ok campaign)
        err-campaign-not-found
    )
)

;; Update campaign status
(define-public (update-campaign-status (campaign-id uint) (new-status (string-ascii 20)))
    (let
        ((campaign (unwrap! (map-get? Campaigns { campaign-id: campaign-id }) err-campaign-not-found)))
        (asserts! (is-eq (get advertiser campaign) tx-sender) err-owner-only)
        
        (map-set Campaigns
            { campaign-id: campaign-id }
            (merge campaign { status: new-status })
        )
        (ok true)
    )
)

;; Record ad view and process payment
(define-public (record-view (campaign-id uint) (publisher principal))
    (let
        ((campaign (unwrap! (map-get? Campaigns { campaign-id: campaign-id }) err-campaign-not-found)))
        
        ;; Verify campaign is active and has budget
        (asserts! (is-eq (get status campaign) "active") err-campaign-expired)
        (asserts! (>= (get remaining-budget campaign) (get cost-per-view campaign)) err-insufficient-balance)
        
        ;; Process payment to publisher
        (try! (as-contract (stx-transfer? (get cost-per-view campaign) tx-sender publisher)))
        
        ;; Update campaign stats
        (map-set Campaigns
            { campaign-id: campaign-id }
            (merge campaign {
                remaining-budget: (- (get remaining-budget campaign) (get cost-per-view campaign)),
                current-views: (+ (get current-views campaign) u1)
            })
        )
        (ok true)
    )
)

;; Initialize contract
(define-data-var campaign-counter uint u0)
