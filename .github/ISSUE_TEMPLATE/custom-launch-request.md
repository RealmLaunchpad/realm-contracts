---
name: Custom Launch Request
about: Describe this issue template's purpose here.
title: 'Custom Launch request:'
labels: ''
assignees: JacoboLansac

---

name: Token launch request
description: Request deployment of a custom token through Realm
title: "[Launch] SYMBOL — Token Name"
labels: ["token-launch"]
body:
  - type: markdown
    attributes:
      value: |
        ## Realm token launch request

        Fill in every section below. The fields map directly to the on-chain
        `createToken` call, so invalid values will be rejected automatically.

        **Tips**
        - Drag-and-drop the token image into the "Token image" box (do not paste a link).
        - Tax is in basis points: `100` = 1%, `1000` = 10% (the protocol max).
        - Addresses must be checksum 0x-prefixed (40 hex chars, mixed case preserved).

  - type: input
    id: name
    attributes:
      label: Token name
      description: 1 to 32 characters. Shown everywhere the token appears.
      placeholder: "My Awesome Token"
    validations:
      required: true

  - type: input
    id: symbol
    attributes:
      label: Token symbol
      description: 1 to 15 characters. UPPERCASE letters and digits only (no spaces, no punctuation).
      placeholder: "MYTOKEN"
    validations:
      required: true

  - type: textarea
    id: description
    attributes:
      label: Description
      description: A paragraph or two about the token. Shown on the Realm app.
      placeholder: "What this token is about, why it exists, who it is for."
    validations:
      required: true

  - type: textarea
    id: image
    attributes:
      label: Token image
      description: |
        Drag-and-drop the image file (PNG, JPG, GIF, or WebP, max 5 MB) into this text area.
        GitHub will replace it with an attachment link — leave that link as-is.
      placeholder: "Drop the image here..."
    validations:
      required: true

  - type: dropdown
    id: network
    attributes:
      label: Target network
      description: Which chain to deploy on.
      options:
        - mainnet
        - sepolia
      default: 0
    validations:
      required: true

  - type: input
    id: fee_receiver
    attributes:
      label: Fee receiver address
      description: 0x-prefixed EVM address that receives the trading fees. Must not be the zero address.
      placeholder: "0x0000000000000000000000000000000000000000"
    validations:
      required: true

  - type: input
    id: buy_tax_bps
    attributes:
      label: Buy tax (bps)
      description: "Integer from 0 to 1000. Examples: 0 = no tax, 100 = 1%, 400 = 4%, 1000 = 10% (max)."
      placeholder: "400"
    validations:
      required: true

  - type: input
    id: sell_tax_bps
    attributes:
      label: Sell tax (bps)
      description: Integer from 0 to 1000. Same units as buy tax.
      placeholder: "400"
    validations:
      required: true

  - type: input
    id: tax_duration_seconds
    attributes:
      label: Tax duration (seconds)
      description: How long the tax stays active. Use 3153600000 for "essentially forever" (100 years).
      value: "3153600000"
    validations:
      required: true

  - type: input
    id: initial_buy_eth
    attributes:
      label: Initial buy (ETH)
      description: Optional. Amount of ETH to spend on an immediate buy at launch. Use 0 to skip.
      value: "0.0"
    validations:
      required: true

  - type: input
    id: telegram
    attributes:
      label: Token Telegram link
      description: Public Telegram channel or group for the token community. Leave blank if none.
      placeholder: "https://t.me/..."

  - type: input
    id: twitter
    attributes:
      label: Token Twitter / X link
      description: Public profile URL. Leave blank if none.
      placeholder: "https://x.com/..."

  - type: input
    id: website
    attributes:
      label: Token website
      description: Must start with `http://` or `https://` (the API will reject bare domains). Leave blank if none.
      placeholder: "https://..."

  - type: input
    id: dev_contact
    attributes:
      label: Your contact (Telegram preferred)
      description: How we can reach you privately if something needs clarification. A Telegram handle like `@yourname` is ideal.
      placeholder: "@yourhandle"
    validations:
      required: true

  - type: input
    id: preferred_launch
    attributes:
      label: Preferred launch date and time
      description: "ISO-ish is best, e.g. `2026-05-15 14:00 UTC`. `ASAP` is also fine."
      placeholder: "2026-05-15 14:00 UTC"
    validations:
      required: true

  - type: checkboxes
    id: acknowledgements
    attributes:
      label: Acknowledgements
      options:
        - label: I have read and agree to the Realm terms of service.
          required: true
        - label: I understand the fee_receiver address is final once deployed.
          required: true
