#ifndef AESHelper_h
#define AESHelper_h

#import <Foundation/Foundation.h>

/// HLS AES-128-CBC 解密包装：CommonCrypto 的 C 函数在 Swift 桥接里不稳定，放到 ObjC 侧调用
@interface AESHelper : NSObject

+ (NSData *)aes128CbcDecrypt:(NSData *)data key:(NSData *)key iv:(NSData *)iv;

@end

#endif /* AESHelper_h */
