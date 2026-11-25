#import "AESHelper.h"

#import <CommonCrypto/CommonCryptor.h>

@implementation AESHelper

+ (NSData *)aes128CbcDecrypt:(NSData *)data key:(NSData *)key iv:(NSData *)iv {
    if (data.length == 0 || key.length != 16 || iv.length != 16) {
        return nil;
    }
    size_t outSize = data.length + kCCBlockSizeAES128;
    NSMutableData *out = [NSMutableData dataWithLength:outSize];
    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt,
                                      kCCAlgorithmAES128,
                                      kCCOptionPKCS7Padding,
                                      key.bytes, key.length,
                                      iv.bytes,
                                      data.bytes, data.length,
                                      out.mutableBytes, outSize,
                                      &moved);
    if (status != kCCSuccess) {
        return nil;
    }
    out.length = moved;
    return out;
}

@end
