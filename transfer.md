#  Mojaloop - Processus de Transfert

Ce document décrit le processus de transfert de fonds conforme à l'API Mojaloop, illustré par deux étapes principales : l'initiation du transfert et l'acceptation du kyc , devis (quote).

---

## 1. Initiation du Transfert

**Méthode HTTP** : `POST`  
**URL** : `http://sdk:4001/transfers`  
**Content-Type** : `application/json`

### 🧾 Corps de la requête :

```json
{
  "homeTransactionId": "c915fa90-d32b-11ef-a4f3-2fd12032756",
  "from": {
    "displayName": "TEST",
    "idType": "MSISDN",
    "idValue": "123456",
    "fspId": "mpm"
  },
  "to": {
    "idType": "MSISDN",
    "idValue": "1234567",
    "fspId": "mpmone"
  },
  "note": "this is a test v2",
  "amountType": "SEND",
  "currency": "XOF",
  "amount": "100",
  "transactionType": "TRANSFER"
}
```
### 2. Acceptation du party
Une fois que le kyc est reçu et évalué par l'expéditeur, il peut être accepté via une requête PUT.

Méthode HTTP : PUT
URL : http://sdk:4001/transfers/{transferId}
Remplacer {transferId} par l'identifiant du transfert retourné à l'étape précédente.

🧾 Corps de la requête :
```json
{
  "acceptParty": true
}
```


### 3. Acceptation du devis (quote)
Une fois que le quote est reçu et évalué par l'expéditeur, il peut être accepté via une requête PUT.

Méthode HTTP : PUT
URL : http://sdk:4001/transfers/{transferId}
Remplacer {transferId} par l'identifiant du transfert retourné à l'étape précédente.

🧾 Corps de la requête :
```json
{
  "acceptQuote": true
}
```
