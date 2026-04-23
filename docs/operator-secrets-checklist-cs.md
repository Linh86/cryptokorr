# Kontrolní seznam operátora — příprava secrets pro Base Sepolia

Kontrolní seznam pro operátora (nemusí být vývojář), který připravuje
secrets a konfiguraci potřebnou pro provisioning Kernelu v3 a pro
ostré testování cryptographic delegation revoke na chainu.

Odpovídá:

- [docs/provisioning-kernel-v3.md](provisioning-kernel-v3.md) —
  kompletní runbook pro provisioning.
- [docs/deploy.md](deploy.md) — obecný postup nasazení Phoenix aplikace.
- [docs/operator-secrets-checklist.md](operator-secrets-checklist.md) —
  anglická verze tohoto checklistu.
- [`chain_adapter/.env.example`](../chain_adapter/.env.example) —
  šablona runtime env, kterou adapter vyžaduje.

Checklist je úmyslně rozdělen na:

- **skutečné secrets** — nikdy nepatří do chatu, ticketů ani Gitu
- **citlivou konfiguraci** — není to privátní klíč, ale může obsahovat
  přihlašovací údaje providera, proto patří do secret store
- **veřejné hodnoty** — v rámci týmu je lze sdílet běžnými kanály

## Co tento checklist připravuje

Tento krok připravuje operátora na budoucí testovací běh proti Base
Sepolia. Cílem je, aby později zbývala už jen operativní práce
(provisioning run a revoke test), ne další konfigurační kolečko.

## Kam hodnoty ukládat

Všechny položky patří do jednoho zabezpečeného záznamu v password
manageru nebo secret store, například:

`CryptoBank / Base Sepolia / Chain Adapter`

Doporučená pole:

- `ADAPTER_DISPATCH_SECRET`
- `ADAPTER_CALLBACK_SECRET`
- `OPERATOR_PRIVATE_KEY`
- `OPERATOR_ADDRESS`
- `DELEGATION_SIGNER_KEY`
- `DELEGATION_SIGNER_PUBKEY`
- `BASE_RPC_URL`
- `BUNDLER_RPC_URL`
- `PHOENIX_BASE_URL`
- `KERNEL_FACTORY_ADDRESS`
- `PERMISSION_VALIDATOR_ADDRESS`
- `SMART_ACCOUNT_ADDRESS`

## Skutečné secrets, které nesmí uniknout

Tyto hodnoty nikdy nepatří do Gitu, chatu ani ticketů:

- `ADAPTER_DISPATCH_SECRET`
- `ADAPTER_CALLBACK_SECRET`
- `OPERATOR_PRIVATE_KEY`
- `DELEGATION_SIGNER_KEY`

Pravidla:

- `OPERATOR_PRIVATE_KEY` a `DELEGATION_SIGNER_KEY` musí být dva různé
  klíče.
- `ADAPTER_DISPATCH_SECRET` a `ADAPTER_CALLBACK_SECRET` musí být dvě
  různé hodnoty.

## Krok za krokem

### 1. Vytvořit `ADAPTER_DISPATCH_SECRET`

Jde o bearer token, kterým se Phoenix prokazuje adapteru při volání
dispatch endpointů.

Token se generuje lokálně:

```bash
openssl rand -hex 32
```

Výstup se uloží jako `ADAPTER_DISPATCH_SECRET`.

### 2. Vytvořit `ADAPTER_CALLBACK_SECRET`

Jde o bearer token pro opačný směr: adapter → Phoenix (callbacky).

Znovu lokálně:

```bash
openssl rand -hex 32
```

Výstup se uloží jako `ADAPTER_CALLBACK_SECRET`. Musí jít o jinou
hodnotu než v kroku 1.

### 3. Vytvořit operator wallet

Vytvořte čerstvý EVM účet určený výhradně pro provisioning smart
accountu a instalaci validatoru.

Doporučený název:

`CryptoBank Operator Sepolia`

Postup:

1. vyexportujte jeho privátní klíč
2. uložte jej jako `OPERATOR_PRIVATE_KEY`
3. uložte jeho veřejnou adresu jako `OPERATOR_ADDRESS`

Nepoužívejte svůj osobní wallet — tento klíč má mít izolovaný životní
cyklus i blast radius.

### 4. Fundnutí operator walletu

Na `OPERATOR_ADDRESS` pošlete Base Sepolia ETH z faucetu. Účet potřebuje
gas na:

- deployment smart accountu
- instalaci validatoru
- opakování verifikace v případě, že něco selže

### 5. Vytvořit delegation signer wallet

Vytvořte druhý oddělený EVM účet pro runtime delegation signing.

Doporučený název:

`CryptoBank Delegation Signer Sepolia`

Postup:

1. vyexportujte jeho privátní klíč
2. uložte jej jako `DELEGATION_SIGNER_KEY`
3. uložte jeho veřejnou adresu jako `DELEGATION_SIGNER_PUBKEY`

Tento klíč **nesmí** být shodný s `OPERATOR_PRIVATE_KEY`.

### 6. Získat `BASE_RPC_URL`

Od vašeho providera získejte Base Sepolia RPC endpoint.

Celé URL uložte jako `BASE_RPC_URL`. Zacházejte s ním jako s citlivou
konfigurací — URL může obsahovat API klíč.

### 7. Získat `BUNDLER_RPC_URL`

Získejte ERC-4337 v0.7 bundler endpoint pro Base Sepolia.

Celé URL uložte jako `BUNDLER_RPC_URL`. Zacházejte s ním jako s citlivou
konfigurací ze stejného důvodu jako u RPC URL.

### 8. Zaznamenat `PHOENIX_BASE_URL`

Jde o base URL Phoenix aplikace, na kterou adapter volá callbacky.

Příklad:

```text
https://staging.example.com
```

Uložte jako `PHOENIX_BASE_URL`.

### 9. Připravit `KERNEL_FACTORY_ADDRESS`

Jde o veřejnou on-chain adresu, ne o secret.

Dohledejte oficiální Kernel v3 factory deployment pro Base Sepolia a
uložte jej jako `KERNEL_FACTORY_ADDRESS`.

Pokud ověřený zdroj od vendora ještě nemáte, nechte pole prázdné —
nevymýšlejte placeholder.

### 10. Připravit `PERMISSION_VALIDATOR_ADDRESS`

Jde rovněž o veřejnou on-chain adresu, ne o secret.

Dohledejte deployment Permission Validatoru pro Base Sepolia a uložte
jej jako `PERMISSION_VALIDATOR_ADDRESS`.

Pokud deployment validatoru ještě nebyl zvolen nebo ověřen, nechte pole
prázdné.

### 11. `SMART_ACCOUNT_ADDRESS` prozatím ponechat prázdné

Tuto hodnotu nevymýšlejte. `SMART_ACCOUNT_ADDRESS` vzniká až při
provisioning runu a vyplňuje se pouze po jeho úspěšném dokončení.

## Kam pak jednotlivá pole patří

| Pole | Typ | Používá |
| --- | --- | --- |
| `ADAPTER_DISPATCH_SECRET` | secret | Phoenix a adapter |
| `ADAPTER_CALLBACK_SECRET` | secret | Phoenix a adapter |
| `OPERATOR_PRIVATE_KEY` | secret | pouze provisioning |
| `OPERATOR_ADDRESS` | veřejná pomocná hodnota | operátorský zápis / fundnutí |
| `DELEGATION_SIGNER_KEY` | secret | runtime adapteru |
| `DELEGATION_SIGNER_PUBKEY` | veřejná hodnota | provisioning |
| `BASE_RPC_URL` | citlivá konfigurace | provisioning a runtime adapteru |
| `BUNDLER_RPC_URL` | citlivá konfigurace | provisioning a runtime adapteru |
| `PHOENIX_BASE_URL` | konfigurace | runtime adapteru |
| `KERNEL_FACTORY_ADDRESS` | veřejná hodnota | provisioning |
| `PERMISSION_VALIDATOR_ADDRESS` | veřejná hodnota | provisioning a později runtime |
| `SMART_ACCOUNT_ADDRESS` | veřejná hodnota | runtime po provisioningu |

## Minimální připravený stav před testováním

Příprava je hotová, když jsou k dispozici všechny z těchto hodnot:

- dva různé bearer secrets
- dva různé wallet privátní klíče
- jeden fundnutý operator wallet na Base Sepolia
- jedna veřejná adresa delegation signeru
- jeden Base Sepolia RPC endpoint
- jeden Base Sepolia ERC-4337 bundler endpoint
- Phoenix base URL

Následující pole mohou zůstat prázdná až do skutečného chain-side
provisioning runu:

- `SMART_ACCOUNT_ADDRESS`
- `KERNEL_FACTORY_ADDRESS`, pokud ještě není potvrzen
- `PERMISSION_VALIDATOR_ADDRESS`, pokud ještě není potvrzen

## Bezpečnostní pravidla

- Privátní klíče ani secrets nikdy nevkládejte do chatu, ticketů ani
  Gitu.
- Žádnou z těchto hodnot necommitujte do repozitáře.
- Nikdy nepoužívejte stejný klíč pro operator funding a pro delegation
  signing.
- Pokud si nejste jistí, zda je hodnota reálná, nechte pole raději
  prázdné než aby zůstal zapomenutý placeholder.
