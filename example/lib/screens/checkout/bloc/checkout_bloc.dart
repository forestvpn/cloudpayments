import 'dart:io';
import 'dart:math';

import 'package:cloudpayments/cloudpayments.dart';
import 'package:cloudpayments/cloudpayments_apple_pay.dart';
import 'package:cloudpayments/cloudpayments_google_pay.dart';
import 'package:equatable/equatable.dart';
import 'package:example/common/extended_bloc.dart';
import 'package:example/constants.dart';
import 'package:example/models/transaction.dart';
import 'package:example/network/api.dart';

part 'checkout_state.dart';
part 'checkout_event.dart';

class CheckoutBloc extends ExtendedBloc<CheckoutEvent, CheckoutState> {
  CheckoutBloc()
      : super(const CheckoutState(
          isLoading: false,
          isGooglePayAvailable: false,
        ));

  final api = Api();
  final googlePay = CloudpaymentsGooglePay(GooglePayEnvironment.test);
  final applePay = CloudpaymentsApplePay();

  @override
  Stream<CheckoutState> mapEventToState(CheckoutEvent event) async* {
    if (event is Init) {
      yield* _init(event);
    } else if (event is PayButtonPressed) {
      yield* _onPayButtonPressed(event);
    } else if (event is Auth) {
      yield* _auth(event);
    } else if (event is Show3DS) {
      yield* _show3DS(event);
    } else if (event is Post3DS) {
      yield* _post3DS(event);
    } else if (event is GooglePayPressed) {
      yield* _googlePayPressed(event);
    } else if (event is ApplePayPressed) {
      yield* _applePayPressed(event);
    } else if (event is Charge) {
      yield* _charge(event);
    }
  }

  Stream<CheckoutState> _init(Init event) async* {
    if (Platform.isAndroid) {
      final isGooglePayAvailable = await googlePay.isGooglePayAvailable();
      yield state.copyWith(
          isGooglePayAvailable: isGooglePayAvailable,
          isApplePayAvailable: false);
    } else if (Platform.isIOS) {
      final isApplePayAvailable = await applePay.isApplePayAvailable();
      yield state.copyWith(
          isApplePayAvailable: isApplePayAvailable,
          isGooglePayAvailable: false);
    }
  }

  Stream<CheckoutState> _onPayButtonPressed(PayButtonPressed event) async* {
    final cardNumber = event.cardNumber;
    final expiryDate = event.expiryDate;
    final cvcCode = event.cvcCode;

    if (cardNumber == null || expiryDate == null || cvcCode == null) {
      yield state.copyWith(cardHolderError: 'Somthing fields is empty');
      return;
    }

    final isCardHolderValid = event.cardHolder?.isNotEmpty ?? false;
    final isValidCardNumber = await Cloudpayments.isValidNumber(cardNumber);
    final isValidExpiryDate = await Cloudpayments.isValidExpiryDate(expiryDate);
    final isValidCvcCode = cvcCode.length == 3;

    if (!isCardHolderValid) {
      yield state.copyWith(cardHolderError: 'Card holder can\'t be blank');
      return;
    } else if (!isValidCardNumber) {
      yield state.copyWith(cardNumberError: 'Invalid card number');
      return;
    } else if (!isValidExpiryDate) {
      yield state.copyWith(expiryDateError: 'Date invalid or expired');
      return;
    } else if (!isValidCvcCode) {
      yield state.copyWith(cvcError: 'Incorrect cvv code');
      return;
    }

    yield state.copyWith(
      cardHolderError: null,
      cardNumberError: null,
      expiryDateError: null,
      cvcError: null,
    );

    final cryptogram = await Cloudpayments.cardCryptogram(
      cardNumber: event.cardNumber!,
      cardDate: event.expiryDate!,
      cardCVC: event.cvcCode!,
      publicId: Constants.MERCHANT_PUBLIC_ID,
    );

    if (cryptogram.cryptogram != null) {
      add(
        Auth(
          cryptogram.cryptogram!,
          event.cardHolder!,
          '1',
        ),
      );
    }
  }

  Stream<CheckoutState> _googlePayPressed(GooglePayPressed event) async* {
    yield state.copyWith(isLoading: true);

    try {
      final result = await googlePay.requestGooglePayPayment(
        price: '2.34',
        currencyCode: 'RUB',
        countryCode: 'RU',
        merchantName: Constants.MERCHANT_NAME,
        publicId: Constants.MERCHANT_PUBLIC_ID,
      );

      yield state.copyWith(isLoading: false);

      if (result.isSuccess) {
        final token = result.token;
        if (token == null) {
          throw Exception('Response token is null');
        }
        add(Charge(token, 'Google Pay', '2.34'));
      } else if (result.isError) {
        sendCommand(ShowSnackBar(result.errorDescription ?? 'error'));
      } else if (result.isCanceled) {
        sendCommand(ShowSnackBar('Google pay has canceled'));
      }
    } catch (e) {
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar("Error"));
    }
  }

  Stream<CheckoutState> _applePayPressed(ApplePayPressed event) async* {
    yield state.copyWith(isLoading: true);

    try {
      final result = await applePay.requestApplePayPayment(
        merchantId: 'merchant.com.YOURDOMAIN',
        currencyCode: 'RUB',
        countryCode: 'RU',
        products: [
          {"name": "Манго", "price": "650.50"}
        ],
      );

      if (result.isSuccess) {
        final token = result.token;
        if (token == null) {
          throw Exception('Response token is null');
        }
        add(Auth(token, '', '650.50'));
      } else if (result.isError) {
        sendCommand(ShowSnackBar(result.errorMessage ?? 'error'));
      } else if (result.isCanceled) {
        sendCommand(ShowSnackBar('Apple pay has canceled'));
      }
    } catch (e) {
      print('Error $e');
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar("Error"));
    }
  }

  Stream<CheckoutState> _charge(Charge event) async* {
    yield state.copyWith(isLoading: true);

    try {
      final transaction =
          await api.charge(event.token, event.cardHolder, event.amount);
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar(transaction.cardHolderMessage));
    } catch (e) {
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar("Error"));
    }
  }

  Stream<CheckoutState> _auth(Auth event) async* {
    yield state.copyWith(isLoading: true);

    try {
      final transaction = await api.auth(
        event.cryptogram,
        event.cardHolder,
        event.amount,
      );

      yield state.copyWith(isLoading: false);
      if (transaction.paReq != null && transaction.acsUrl != null) {
        add(Show3DS(transaction));
      } else {
        sendCommand(ShowSnackBar(transaction.cardHolderMessage));
      }
    } catch (e) {
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar("Error"));
    }
  }

  Stream<CheckoutState> _show3DS(Show3DS event) async* {
    final transaction = event.transaction;
    final result = await Cloudpayments.show3ds(
      acsUrl: transaction.acsUrl,
      transactionId: transaction.transactionId,
      paReq: transaction.paReq,
    );

    if (result != null) {
      if (result.success ?? false) {
        add(Post3DS(result.md!, result.paRes!));
      } else {
        sendCommand(ShowSnackBar(result.error ?? 'error'));
      }
    }
  }

  Stream<CheckoutState> _post3DS(Post3DS event) async* {
    yield state.copyWith(isLoading: true);

    try {
      final transaction = await api.post3ds(event.md, event.paRes);
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar(transaction.cardHolderMessage));
    } catch (e) {
      yield state.copyWith(isLoading: false);
      sendCommand(ShowSnackBar("Error"));
    }
  }
}