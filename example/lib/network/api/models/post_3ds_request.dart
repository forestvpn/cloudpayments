class Post3dsRequest {
  final String transactionId;
  final String paRes;

  Post3dsRequest(this.transactionId, this.paRes);

  Map<String, dynamic> toJson() {
    final map = Map<String, dynamic>();

    map['TransactionId'] = transactionId;
    map['PaRes'] = paRes;

    return map;
  }
}
