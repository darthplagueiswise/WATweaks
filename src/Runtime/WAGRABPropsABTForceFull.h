#pragma once

#import <Foundation/Foundation.h>
#import "WAGRABPropsABTLiveService.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Runs the correlated ABT transaction while forcing the concrete
/// XMPPRequestABProperties constructor to receive configHash=nil and
/// refreshID=nil. This keeps WhatsApp's native request/decoder/store pipeline,
/// but removes the two cache validators that allow the server to answer with a
/// successful zero-prop no-change response.
BOOL WAGRABPropsABTLiveFetchForcedFull(id _Nullable userContext,
                                       WAGRABPropsABTLiveCompletion _Nullable completion,
                                       NSString * _Nullable * _Nullable diagnostic);

/// Runtime evidence for the forced-full constructor bridge.
NSDictionary<NSString *, id> *WAGRABPropsABTForceFullDocument(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
