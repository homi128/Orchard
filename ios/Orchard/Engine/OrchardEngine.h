// Puente entre Swift y el motor compartido de Orchard (QuickJS + provider host).
// El motor corre en su propio hilo con pila de 8 MiB, como en escritorio y Android.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^OrchardEngineCompletion)(BOOL ok, NSString *result);

@interface OrchardEngine : NSObject

+ (instancetype)shared;

/// Llama `invoke(method, payload)` del proveedor de YouTube.
/// `payloadJSON` es JSON; el resultado llega en el hilo principal: JSON si ok, mensaje si falló.
- (void)invoke:(NSString *)method
       payload:(NSString *)payloadJSON
    completion:(OrchardEngineCompletion)completion;

@end

NS_ASSUME_NONNULL_END
