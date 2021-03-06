/*
 * Copyright (c) 2017, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <PsiCashLib/PsiCash.h>
#import <PsiCashLib/PsiCashAPIModels.h>
#import "PsiCashClient.h"
#import "AppDelegate.h"
#import "AppInfo.h"
#import "Asserts.h"
#import "Authorization.h"
#import "CustomIOSAlertView.h"
#import "Logging.h"
#import "Notifier.h"
#import "PsiCashAuthPackage.h"
#import "PsiCashClientModel.h"
#import "PsiCashTypes.h"
#import "PsiCashLogger.h"
#import "PsiCashSpeedBoostProduct+PsiCashPurchasePrice.h"
#import "PsiphonDataSharedDB.h"
#import "RACSignal+Operations2.h"
#import "ReactiveObjC.h"
#import "SharedConstants.h"
#import "NSError+Convenience.h"
#import "VPNManager.h"
#import "NSString+Additions.h"

@interface PsiCashClient ()

@property (nonatomic, readwrite) RACReplaySubject<PsiCashClientModel *> *clientModelSignal;

@property (nonatomic, readwrite) RACBehaviorSubject<NSString *> *rewardedActivityDataSignal;

@end

NSErrorDomain const PsiCashClientLibraryErrorDomain = @"PsiCashClientLibraryErrorDomain";
NSErrorDomain const PsiCashClientRefreshStateErrorDomain = @"PsiCashClientRefreshStateErrorDomain";

typedef NS_ERROR_ENUM(PsiCashClientRefreshStateErrorDomain, PsiCashClientRefreshStateErrorCode) {
    PsiCashClientRefreshStateErrorSuccessButPredicateFalse = -1,
};

@implementation PsiCashClient {
    PsiCash *psiCash;
    PsiCashLogger *logger;

    // Offload work from PsiCashLib's internal completion queue
    dispatch_queue_t completionQueue;

    PsiCashClientModel *model;
    PsiphonDataSharedDB *sharedDB;

    VPNManager *vpnManager;
    RACDisposable *tunnelStatusDisposable;
    RACDisposable *refreshDisposable;
    RACDisposable *pollForBalanceDeltaDisposable;
    RACDisposable *purchaseDisposable;
}

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        psiCash = [[PsiCash alloc] init];

        [self setStaticRequestMetadata];

        logger = [[PsiCashLogger alloc] initWithClient:psiCash];

        sharedDB = [[PsiphonDataSharedDB alloc] initForAppGroupIdentifier:APP_GROUP_IDENTIFIER];

        completionQueue = dispatch_queue_create("com.psiphon3.PsiCashClient.CompletionQueue",
                                                DISPATCH_QUEUE_SERIAL);

        _clientModelSignal = [RACReplaySubject replaySubjectWithCapacity:1];

        _rewardedActivityDataSignal = [RACBehaviorSubject behaviorSubjectWithDefaultValue:nil];

        vpnManager = [VPNManager sharedInstance];
    }
    return self;
}

#pragma mark - Refresh state

- (void)scheduleRefreshState {
    __weak PsiCashClient *weakSelf = self;
    [tunnelStatusDisposable dispose];

    // Observe VPN status for updating UI state
    tunnelStatusDisposable = [vpnManager.lastTunnelStatus
                              subscribeNext:^(NSNumber *statusObject) {
                                  VPNStatus s = (VPNStatus) [statusObject integerValue];

                                  if (s == VPNStatusConnected) {
                                      // refresh state from server with lib
                                      [weakSelf refreshStateRemote];
                                  } else {
                                      // cancel the request in flight
                                      [refreshDisposable dispose];

                                       // refresh state locally from lib
                                      [weakSelf refreshStateLocal];
                                  }
                              }];
}

#pragma mark - Cached Refresh

- (void)refreshStateLocal {
    [self updateContainerAuthTokens];

    PsiCashClientModelStagingArea *stagingArea = [self stagingAreaFromLib];
    [self commitModelStagingArea:stagingArea];
}

- (PsiCashClientModelStagingArea*)stagingAreaFromLib {
    PsiCashClientModelStagingArea *stagingArea = [[PsiCashClientModelStagingArea alloc]
      initWithModel:model];

    [stagingArea updateRefreshPending:NO];
    [stagingArea updateBalance:psiCash.balance];
    [stagingArea updateActivePurchases:[self activePurchases]];

    if (psiCash.validTokenTypes) {
        [stagingArea updateAuthPackage:[[PsiCashAuthPackage alloc]
          initWithValidTokens:psiCash.validTokenTypes]];
    } else {
        [stagingArea updateAuthPackage:[[PsiCashAuthPackage alloc] init]];
    }

    if (psiCash.purchasePrices) {
        [stagingArea updateSpeedBoostProduct:
                       [self speedBoostProductFromPurchasePrices:psiCash.purchasePrices
                                              withTargetProducts:[self targetProducts]]];
    }

    return stagingArea;
}

#pragma mark - Refresh Signal

/*
 *  ********************************** NOTE **********************************
 *  refreshStateRemote and pollForBalanceDelta will make redundant network
 *  requests if used in parallel. Since both signals have different predicates
 *  and retry times (exponential vs. fixed) there is not an simple solution to
 *  mitigate this redundancy. In the future these signals could be serialized
 *  or merged if this becomes an issue. One idea would be to combine retry
 *  times and sort them in ascending order and combine predicates.
 *  **************************************************************************
 */

- (void)refreshStateRemote {
#if DEBUG
    const int networkRetryCount = 3;
#else
    const int networkRetryCount = 6;
#endif

    BOOL (^predicate)(void) = ^BOOL(void) {
        return YES;
    };

    NSTimeInterval (^nextRetryTime)(long) = ^NSTimeInterval(long retryNum) {
        return pow(4, retryNum);
    };

    [refreshDisposable dispose];
    refreshDisposable = [self refreshStateWithMaxRetries:networkRetryCount
                                   andTimeBetweenRetries:nextRetryTime
                                            andPredicate:predicate
                                        andTagForLogging:@"RefreshState"];
}

- (void)pollForBalanceDeltaWithMaxRetries:(int)maxRetries
                    andTimeBetweenRetries:(NSTimeInterval)timeBetweenRetries {

    NSNumber *startingBalance = [psiCash.balance copy];

    BOOL (^predicate)(void) = ^BOOL(void) {
        return [psiCash.balance compare:startingBalance] != NSOrderedSame;
    };

    NSTimeInterval (^nextRetryTime)(long) = ^NSTimeInterval(long retryNum) {
        return timeBetweenRetries;
    };

    [pollForBalanceDeltaDisposable dispose];
    pollForBalanceDeltaDisposable = [self refreshStateWithMaxRetries:maxRetries
                                               andTimeBetweenRetries:nextRetryTime
                                                        andPredicate:predicate
                                                    andTagForLogging:@"PollForBalanceDelta"];
}

- (RACDisposable*)refreshStateWithMaxRetries:(int)maxRetries
                       andTimeBetweenRetries:(NSTimeInterval (^)(long))timeBetweenRetries
                                andPredicate:(BOOL (^)(void))predicate
                            andTagForLogging:(NSString*)tag {

    [logger logEvent:[tag stringByAppendingString:@"Started"] includingDiagnosticInfo:YES];
    [self setDynamicRequestMetadata];

    RACSignal *refresh = [[[[[self refreshStateFromServer]
        startWith:[PsiCashRefreshResultModel inProgress]]
        flattenMap:^RACSignal *(PsiCashRefreshResultModel * _Nullable r) {

            if (r.inProgress) {
                PsiCashClientModelStagingArea *stagingArea = [self stagingAreaFromLib];
                [stagingArea updateRefreshPending:YES];
                [stagingArea updateActivePurchases:[self activePurchases]];
                [self commitModelStagingArea:stagingArea];
            } else {
                // Lib has been updated with results from server
                [self refreshStateLocal];
            }

            if (predicate()) {
                return [RACSignal return:[RACUnit defaultUnit]];
            } else {
                NSError *err = [NSError errorWithDomain:PsiCashClientRefreshStateErrorDomain
                                         code:PsiCashClientRefreshStateErrorSuccessButPredicateFalse
                      andLocalizedDescription:@"PredicateFalse"];

                return [RACSignal error:err];
            }
        }]
        retryWhen:^RACSignal *(RACSignal *_Nonnull errors) {
            return [[errors
                zipWith:[RACSignal rangeStartFrom:1 count:maxRetries]]
                flattenMap:^RACSignal *(RACTwoTuple<NSError *, NSNumber *> *retryCountTuple) {
                // NOTE: errors from refreshStateFromServer forwarded here as well

                // Emits the error on the last retry.
                if ([retryCountTuple.second integerValue] == maxRetries) {
                    return [RACSignal error:retryCountTuple.first];
                }
                // Wait before retrying again.
                return [RACSignal timer:timeBetweenRetries([retryCountTuple.second integerValue])];
            }];
        }]
        catch:^RACSignal *(NSError *_Nonnull error) {
            // Else re-emit the error.
            return [RACSignal error:error];
    }];

    refreshDisposable = [refresh subscribeNext:^(id  _Nullable x) {
        // Nothing to handle here
    } error:^(NSError * _Nullable error) {
        PsiCashClientModelStagingArea *stagingArea = [self stagingAreaFromLib];
        [stagingArea updateRefreshPending:NO];
        [self commitModelStagingArea:stagingArea];

        [logger logErrorEvent:[tag stringByAppendingString:@"Failed"]
                        withError:error
          includingDiagnosticInfo:NO];
    } completed:^{
        [logger logEvent:[tag stringByAppendingString:@"Completed"] includingDiagnosticInfo:YES];
    }];

    return refreshDisposable;
}

- (RACSignal<PsiCashRefreshResultModel*>*)refreshStateFromServer {

    return [RACSignal createSignal:^RACDisposable *(id<RACSubscriber>  _Nonnull subscriber) {

        [psiCash refreshState:@[[PsiCashSpeedBoostProduct purchaseClass]]
               withCompletion:^(PsiCashStatus status, NSError * _Nullable error) {

                if (error != nil) {
                    // If error non-nil, the request failed utterly and no other params are valid.
                    dispatch_async(self->completionQueue, ^{
                        [subscriber sendError:error];
                    });
                } else if (status == PsiCashStatus_Success) {
                    dispatch_async(self->completionQueue, ^{
                        [subscriber sendNext:[PsiCashRefreshResultModel success]];
                        [subscriber sendCompleted];
                    });
                } else {
                    NSError *e;
                    if (status == PsiCashStatus_ServerError) {
                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:status
                             andLocalizedDescription:@"Server error"];

                    } else if (status == PsiCashStatus_Invalid) {
                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:status
                             andLocalizedDescription:@"Invalid response"];

                    } else if (status == PsiCashStatus_InvalidTokens) {
                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:status
                             andLocalizedDescription:@"Invalid Tokens: the app has entered an"
                                                     " invalid state. Please reinstall the app"
                                                     " to continue using PsiCash."];

                    } else {
                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:status
                             andLocalizedDescription:@"Invalid or unexpected status code returned"
                                                     " from PsiCash library"];
                    }
                    dispatch_async(self->completionQueue, ^{
                        [subscriber sendError:e];
                    });
                }
         }];
        return nil;
    }];
}

#pragma mark - Purchase Signal

- (void)purchaseSpeedBoostProduct:(PsiCashSpeedBoostProductSKU*)sku {
    [logger logEvent:@"Purchase" withInfoDictionary:[sku jsonDict] includingDiagnosticInfo:NO];
    [self setDynamicRequestMetadata];

    [purchaseDisposable dispose];

    RACSignal *makePurchase = [
      [self makeExpiringPurchaseTransactionForClass:[PsiCashSpeedBoostProduct purchaseClass]
                                   andDistinguisher:sku.distinguisher
                                  withExpectedPrice:sku.price]
            startWith:[PsiCashMakePurchaseResultModel inProgress]];

    purchaseDisposable = [makePurchase
      subscribeNext:^(PsiCashMakePurchaseResultModel *_Nullable result) {

        if (result.inProgress) {

            PsiCashClientModelStagingArea *pendingPurchasesStagingArea = [self stagingAreaFromLib];
            [pendingPurchasesStagingArea updatePendingPurchases:@[sku]];
            [self commitModelStagingArea:pendingPurchasesStagingArea];

        } else {

            PsiCashClientModelStagingArea *stagingArea = [self stagingAreaFromLib];
            [stagingArea updatePendingPurchases:nil];
            [self commitModelStagingArea:stagingArea];

            if (result.status == PsiCashStatus_Success) {

                // Validate the new authorization

                Authorization *authorization = [[Authorization alloc]
                  initWithEncodedAuthorization:result.purchase.authorization];
                NSError *e = nil;

                if (authorization == nil) {
                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:@"Got nil auth token from PsiCash library"];
                }

                if (![authorization.accessType
                       isEqualToString:[PsiCashSpeedBoostProduct purchaseClass]]) {

                    NSString *s = [NSString stringWithFormat:@"Got auth token from PsiCash library"
                                                             " with wrong purchase class of %@",
                                                             authorization.accessType];

                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:s];
                }

                [self updateContainerAuthTokens];
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Ensure homepage is shown when extension reconnects with new auth token
                    [AppDelegate sharedAppDelegate].shownLandingPageForCurrentSession = FALSE;
                });

                [[Notifier sharedInstance] post:NotifierUpdatedAuthorizations];

                if (e != nil) {
                    [logger logErrorEvent:@"PurchaseResultInvalid"
                                    withError:e
                      includingDiagnosticInfo:NO];
                }

            } else {

                NSError *e = nil;
                if (result.status == PsiCashStatus_ExistingTransaction) {
                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_ALREADY_ACTIVE_PURCHASE", nil, [NSBundle mainBundle], @"Error: you already have an active Speed Boost purchase.", @"Alert error message informing user that their Speed Boost purchase request failed because they already have an active Speed Boost purchase. 'Speed Boost' is a reward that can be purchased with PsiCash credit. It provides unlimited network connection speed through Psiphon. Other words that can be used to help with translation are: 'turbo' (like cars), 'accelerate', 'warp speed', 'blast off', or anything that indicates a fast or unrestricted speed.")];

                } else if (result.status == PsiCashStatus_InsufficientBalance) {

                    NSString *s = NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_INSUFFICIENT_FUNDS", nil, [NSBundle mainBundle], @"Insufficient balance for Speed Boost purchase. Price:", @"Alert error message informing user that their Speed Boost purchase request failed because they have an insufficient balance. Required price in PsiCash will be appended after the colon. 'Speed Boost' is a reward that can be purchased with PsiCash credit. It provides unlimited network connection speed through Psiphon. Other words that can be used to help with translation are: 'turbo' (like cars), 'accelerate', 'warp speed', 'blast off', or anything that indicates a fast or unrestricted speed.");
                    s = [s stringByAppendingString:[NSString stringWithFormat:@" %@",
                                            [PsiCashClientModel formattedBalance:psiCash.balance]]];

                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:s];

                } else if (result.status == PsiCashStatus_TransactionAmountMismatch) {

                    // Check if local products have been updated
                    PsiCashSpeedBoostProductSKU *updatedSKU =
                      [stagingArea.stagedModel.speedBoostProduct
                        productSKUWithDistinguisher:sku.distinguisher];

                    if (!updatedSKU) {
                        // Product no longer exists
                        NSString *s = NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_PRODUCT_NOT_FOUND", nil, [NSBundle mainBundle], @"Error: Speed Boost product not found. Local products updated. Your app may be out of date. Please check for updates.", @"Alert error message informing user that their Speed Boost purchase request failed because they attempted to buy a product that is no longer available and that they should try updating or reinstalling the app. 'Speed Boost' is a reward that can be purchased with PsiCash credit. It provides unlimited network connection speed through Psiphon. Other words that can be used to help with translation are: 'turbo' (like cars), 'accelerate', 'warp speed', 'blast off', or anything that indicates a fast or unrestricted speed.");
                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:result.status
                             andLocalizedDescription:s];

                        // Attempt to sync new products from the server
                        [self refreshStateRemote];

                    } else if ([updatedSKU.price compare:sku.price] == NSOrderedSame) {
                        // Product price has not changed
                        NSString *s = NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_PRICE_OUT_OF_DATE_NO_MISMATCH", nil, [NSBundle mainBundle], @"Error: price of Speed Boost is out of date. Updating local products.", @"Alert error message informing user that their Speed Boost purchase request failed because they tried to make the purchase with an out of date product price and that the price is being updated. 'Speed Boost' is a reward that can be purchased with PsiCash credit. It provides unlimited network connection speed through Psiphon. Other words that can be used to help with translation are: 'turbo' (like cars), 'accelerate', 'warp speed', 'blast off', or anything that indicates a fast or unrestricted speed.");
                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:result.status
                             andLocalizedDescription:s];

                        // Attempt to sync new products from the server
                        [self refreshStateRemote];

                    } else {
                        // Product price has changed
                        NSString *s = NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_PRICE_OUT_OF_DATE", nil, [NSBundle mainBundle], @"Error: price of Speed Boost is out of date. Price:", @"Alert error message informing user that their Speed Boost purchase request failed because they tried to make the purchase with an out of date product price. Updated price will be appended after the colon. 'Speed Boost' is a reward that can be purchased with PsiCash credit. It provides unlimited network connection speed through Psiphon. Other words that can be used to help with translation are: 'turbo' (like cars), 'accelerate', 'warp speed', 'blast off', or anything that indicates a fast or unrestricted speed.");
                        s = [s stringByAppendingString:
                          [NSString stringWithFormat:@" %@", [PsiCashClientModel
                            formattedBalance:updatedSKU.price]]];

                        e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                                code:result.status
                             andLocalizedDescription:s];
                    }

                } else if (result.status == PsiCashStatus_TransactionTypeNotFound) {
                    NSString *s = NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_PRODUCT_NOT_FOUND", nil, [NSBundle mainBundle], @"Error: Speed Boost product not found. Local products updated. Your app may be out of date. Please check for updates.", @"Alert error message informing user that their Speed Boost purchase request failed because they attempted to buy a product that is no longer available and that they should try updating or reinstalling the app. 'Speed Boost' is a reward that can be purchased with PsiCash credit. It provides unlimited network connection speed through Psiphon. Other words that can be used to help with translation are: 'turbo' (like cars), 'accelerate', 'warp speed', 'blast off', or anything that indicates a fast or unrestricted speed.");
                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:s];

                    [stagingArea removeSpeedBoostProductSKU:sku];

                } else if (result.status == PsiCashStatus_InvalidTokens) {
                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_INVALID_TOKENS", nil, [NSBundle mainBundle], @"Invalid Tokens: the app has entered an invalid state. Please reinstall the app to continue using PsiCash.", @"Alert error message informing user that their Speed Boost purchase request failed because their app has entered an invalid state and that they should try updating or reinstalling the app. Note: 'PsiCash' should not be translated or transliterated.")];

                } else if (result.status == PsiCashStatus_ServerError) {
                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_SERVER_ERROR", nil, [NSBundle mainBundle], @"Server error. Please try again in a few minutes.", @"Alert error message informing user that their Speed Boost purchase request failed due to a server error and that they should try again in a few minutes")];

                } else {
                    e = [NSError errorWithDomain:PsiCashClientLibraryErrorDomain
                                            code:result.status
                         andLocalizedDescription:NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_UNEXPECTED_CODE", nil, [NSBundle mainBundle], @"Invalid or unexpected status code returned from PsiCash library.", @"Alert error message informing user that their Speed Boost purchase request failed because of an unknown error. Note: 'PsiCash' should not be translated or transliterated.")];
                }

                if (e != nil) {
                    [self displayAlertWithMessage:e.localizedDescription];
                    [logger logErrorEvent:@"PurchaseFailed"
                                    withError:e
                      includingDiagnosticInfo:YES];
                }
            }
        }

    } error:^(NSError * _Nullable error) {
        PsiCashClientModelStagingArea *stagingArea = [self stagingAreaFromLib];
        [stagingArea updatePendingPurchases:nil];
        [self commitModelStagingArea:stagingArea];

        [logger logErrorEvent:@"PurchaseFailed" withError:error includingDiagnosticInfo:YES];
        [self displayAlertWithMessage:NSLocalizedStringWithDefaultValue(@"PSICASH_SPEED_BOOST_PURCHASE_FAILED_MESSAGE_TEXT", nil, [NSBundle mainBundle], @"Purchase failed, please try again in a few minutes.", @"Alert message informing user that their Speed Boost purchase attempt unexpectedly failed and that they should try again in a few minutes.")];
    } completed:^{
        [logger logEvent:@"PurchaseSuccess" includingDiagnosticInfo:YES];
    }];
}

- (RACSignal<PsiCashMakePurchaseResultModel*>*)makeExpiringPurchaseTransactionForClass:
                                                                         (NSString*)transactionClass
                                                         andDistinguisher:(NSString*)distinguisher
                                                        withExpectedPrice:(NSNumber*)expectedPrice {

    return [RACSignal createSignal:^RACDisposable *(id<RACSubscriber>  _Nonnull subscriber) {
        [psiCash newExpiringPurchaseTransactionForClass:transactionClass
                                      withDistinguisher:distinguisher
                                      withExpectedPrice:expectedPrice
                                         withCompletion:^(PsiCashStatus status,
                                                          PsiCashPurchase * _Nullable purchase,
                                                          NSError * _Nullable error) {

            dispatch_async(self->completionQueue, ^{
                if (error != nil) {
                    // If error non-nil, the request failed utterly and no other params are valid.
                    [subscriber sendError:error];
                } else {
                    [subscriber sendNext:[PsiCashMakePurchaseResultModel successWithStatus:status
                                                                               andPurchase:purchase
                                                                                  andError:nil]];
                    [subscriber sendCompleted];
                }
            });
        }];
        return nil;
    }];
}

#pragma mark - Home Pages

- (NSURL*)modifiedHomePageURL:(NSURL*)url {
    NSString *modifiedURL = nil;

    NSError *e = [psiCash modifyLandingPage:[url absoluteString] modifiedURL:&modifiedURL];
    if (e!= nil) {
        [logger logErrorEvent:@"ModifyURLFailed" withError:e includingDiagnosticInfo:YES];
        return url;
    }

    return [NSURL URLWithString:modifiedURL];
}

#pragma mark - Rewarded videos

- (NSString*)rewardedVideoCustomData {
    NSString *s;
    NSError *e = [psiCash getRewardedActivityData:&s];
    if (e) {
        [logger logErrorEvent:@"GetRewardedActivityDataFailed"
                        withError:e
          includingDiagnosticInfo:YES];
        return nil;
    }
    return s;
}

#pragma mark - PsiCashLib request metadata

- (void)setStaticRequestMetadata {
    NSString *appVersion = [AppInfo appVersion];
    if (appVersion) {
        [psiCash setRequestMetadataAtKey:@"client_version" withValue:appVersion];
    }

    NSString *propagationChannelId = [AppInfo propagationChannelId];
    if (propagationChannelId) {
        [psiCash setRequestMetadataAtKey:@"propagation_channel_id" withValue:propagationChannelId];
    }
}

- (void)setDynamicRequestMetadata {
    NSString *clientRegion = [AppInfo clientRegion];
    if (clientRegion) {
        [psiCash setRequestMetadataAtKey:@"client_region" withValue:clientRegion];
    }

    NSString *sponsorId = [AppInfo sponsorId];
    if (sponsorId) {
        [psiCash setRequestMetadataAtKey:@"sponsor_id" withValue:sponsorId];
    }
}

#pragma mark - Logging

- (NSString*)logForFeedback {
    return [logger logForFeedback];
}

#pragma mark - Authorization expiries

// See comment in header
- (void)authorizationsMarkedExpired {
    PsiCashClientModelStagingArea *stagingArea = [self stagingAreaFromLib];
    [stagingArea updateActivePurchases:[self activePurchases]];
    [self commitModelStagingArea:stagingArea];
}

/**
 * Returns the set of active purchases from the PsiCash library subtracted by the set
 * of purchases marked as expired by the extension. This handles the scenario where
 * the server has decided a purchase is expired before the library. In this scenario
 * the server should be treated as the ultimate source of truth and these expired
 * purchases will be removed from the library.
 *
 * @return Returns {setActivePurchaseLib | x is not marked expired by the extension}
 */
- (NSArray<PsiCashPurchase*>*)activePurchases {
    NSMutableArray <PsiCashPurchase*>* purchases = [[NSMutableArray alloc]
      initWithArray:[[psiCash purchases] copy]];

    NSSet<NSString *> *markedAuthIDs = [sharedDB getMarkedExpiredAuthorizationIDs];
    NSMutableArray *purchasesToRemove = [[NSMutableArray alloc] init];

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(PsiCashPurchase *evaluatedObject,
                                                 NSDictionary<NSString *,id> * _Nullable bindings) {

        Authorization *auth = [[Authorization alloc]
          initWithEncodedAuthorization:evaluatedObject.authorization];

        if ([markedAuthIDs containsObject:auth.ID]) {
            [purchasesToRemove addObject:evaluatedObject.ID];
            return FALSE;
        }
        return TRUE;
    }];
    [purchases filterUsingPredicate:predicate];

    // Remove purchases indicated as expired by the Psiphon server, but not yet by the PsiCash lib.
    // This will occur if the local clock is out of sync with that of the PsiCash server.
    [psiCash removePurchases:purchasesToRemove];

    return purchases;
}

#pragma mark - Helpers

- (void)commitModelStagingArea:(PsiCashClientModelStagingArea *)stagingArea {

    dispatch_async(dispatch_get_main_queue(), ^{

        [self.clientModelSignal sendNext:stagingArea.stagedModel];

        // We take this opportunity to set the value of the custom data signal.
        // To prevent unnecessary computation, custom data is checked for change.
        NSString *_Nullable prvCustomData = [self.rewardedActivityDataSignal first];
        NSString *_Nullable curCustomData = [self rewardedVideoCustomData];

        if (![NSString stringsBothEqualOrNil:prvCustomData b:curCustomData]) {
            [self.rewardedActivityDataSignal sendNext:curCustomData];
        }
    });
    model = stagingArea.stagedModel;
}

- (void)displayAlertWithMessage:(NSString*)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        CustomIOSAlertView *alert = [[CustomIOSAlertView alloc] init];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 250, 150)];
        l.adjustsFontSizeToFitWidth = YES;
        l.font = [UIFont systemFontOfSize:12.f];
        l.numberOfLines = 0;
        l.text = msg;
        l.textAlignment = NSTextAlignmentCenter;

        alert.containerView = l;
        [alert show];
    });
}

/**
 * Hardcode SpeedBoost product to only 1h option for PsiCash 1.0
 */
- (NSDictionary<NSString*,NSArray<NSString*>*>*)targetProducts {
    return @{[PsiCashSpeedBoostProduct purchaseClass]: @[@"1hr"]};
}

/**
 * Helper function to parse an array of PsiCashPurchasePrice objects
 * into a more completely typed PsiCashSpeedBoostProduct object.
 */
- (PsiCashSpeedBoostProduct*)speedBoostProductFromPurchasePrices:(NSArray<PsiCashPurchasePrice*>*)
  purchasePrices withTargetProducts:(NSDictionary<NSString*,NSArray<NSString*>*>*)targets {

    NSMutableArray<PsiCashPurchasePrice*> *speedBoostPurchasePrices = [[NSMutableArray alloc] init];
    NSArray <NSString*>* targetDistinguishersForSpeedBoost = nil;
    if (targets != nil) {
        targetDistinguishersForSpeedBoost = targets[[PsiCashSpeedBoostProduct purchaseClass]];
    }

    for (PsiCashPurchasePrice *price in purchasePrices) {
        if ([price.transactionClass isEqualToString:[PsiCashSpeedBoostProduct purchaseClass]]) {
            if (targetDistinguishersForSpeedBoost == nil ||
                [targetDistinguishersForSpeedBoost containsObject:price.distinguisher]) {

                [speedBoostPurchasePrices addObject:price];
            }
        } else {
            [logger logEvent:@"IgnoredPurchasePrice"
                   withInfoDictionary:[price toDictionary]
              includingDiagnosticInfo:NO];
        }
    }

    PsiCashSpeedBoostProduct *speedBoostProduct = nil;
    if ([speedBoostPurchasePrices count] == 0) {
        [logger logErrorEvent:@"NoSpeedBoostProductSKUsFound"
                         withInfo:nil
          includingDiagnosticInfo:YES];

    } else {
        speedBoostProduct = [PsiCashSpeedBoostProduct
          productWithPurchasePrices:speedBoostPurchasePrices];
    }

    return speedBoostProduct;
}

- (void)updateContainerAuthTokens {
    [sharedDB setContainerAuthorizations:[self speedBoostAuthorizations]];
}

- (NSSet<Authorization*>*)speedBoostAuthorizations {
    NSMutableSet <Authorization*>*validAuthorizations = [[NSMutableSet alloc] init];

    NSArray <PsiCashPurchase*>* purchases = psiCash.purchases;
    for (PsiCashPurchase *purchase in purchases) {
        if ([purchase.transactionClass isEqualToString:[PsiCashSpeedBoostProduct purchaseClass]]) {
            [validAuthorizations addObject:[[Authorization alloc]
              initWithEncodedAuthorization:purchase.authorization]];
        }
    }

    return validAuthorizations;
}

@end
