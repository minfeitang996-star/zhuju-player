#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ONNX Runtime 推理包装：加载编码器 / 解码器两个 ONNX，按 token id 做贪心解码。
/// 分词由 Swift 侧完成，这里只负责张量计算。
@interface MTTranslator : NSObject

/// 加载编码器和解码器模型文件；失败返回 nil 并填充 error。
- (nullable instancetype)initWithEncoderPath:(NSString *)encoderPath
                                decoderPath:(NSString *)decoderPath
                                      error:(NSError **)error;

/// 输入源 token id（已补 EOS），返回目标侧 token id（不含起始 pad 和 EOS）。
- (nullable NSArray<NSNumber *> *)translateSourceIds:(const int64_t *)ids
                                               count:(NSInteger)count
                                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
