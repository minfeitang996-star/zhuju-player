#import "MTTranslator.h"

#include <onnxruntime/onnxruntime_c_api.h>

#include <vector>
#include <string>
#include <limits>

namespace {
constexpr int64_t kPadToken = 65000;
constexpr int64_t kEosToken = 0;
constexpr int kMaxOutputTokens = 64;

const OrtApi* ortApi(void) {
    return OrtGetApiBase()->GetApi(ORT_API_VERSION);
}
}

@interface MTTranslator () {
    OrtEnv* _env;
    OrtSession* _encoder;
    OrtSession* _decoder;
    OrtSessionOptions* _sessionOptions;
    OrtMemoryInfo* _memoryInfo;
}
@end

@implementation MTTranslator

- (nullable instancetype)initWithEncoderPath:(NSString *)encoderPath
                                decoderPath:(NSString *)decoderPath
                                      error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }

    const OrtApi* api = ortApi();
    OrtStatus* status = NULL;

    status = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "zhuju-mt", &_env);
    if (status) { goto fail; }

    status = api->CreateSessionOptions(&_sessionOptions);
    if (status) { goto fail; }
    if (api->SetIntraOpNumThreads(_sessionOptions, 2)) { goto fail; }
    if (api->SetSessionGraphOptimizationLevel(_sessionOptions, ORT_ENABLE_BASIC)) { goto fail; }

    status = api->CreateSession(_env, [encoderPath UTF8String], _sessionOptions, &_encoder);
    if (status) { goto fail; }
    status = api->CreateSession(_env, [decoderPath UTF8String], _sessionOptions, &_decoder);
    if (status) { goto fail; }

    status = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeCPU, &_memoryInfo);
    if (status) { goto fail; }

    return self;

fail:
    if (status) {
        const char* msg = api->GetErrorMessage(status);
        if (error) {
            *error = [NSError errorWithDomain:@"MTTranslator" code:1
                userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithUTF8String:msg ?: "模型加载失败"] }];
        }
        api->ReleaseStatus(status);
    } else if (error) {
        *error = [NSError errorWithDomain:@"MTTranslator" code:1
            userInfo:@{ NSLocalizedDescriptionKey: @"模型加载失败" }];
    }
    if (_encoder) { api->ReleaseSession(_encoder); _encoder = NULL; }
    if (_decoder) { api->ReleaseSession(_decoder); _decoder = NULL; }
    if (_sessionOptions) { api->ReleaseSessionOptions(_sessionOptions); _sessionOptions = NULL; }
    if (_memoryInfo) { api->ReleaseMemoryInfo(_memoryInfo); _memoryInfo = NULL; }
    if (_env) { api->ReleaseEnv(_env); _env = NULL; }
    return nil;
}

- (void)dealloc {
    const OrtApi* api = ortApi();
    if (_encoder) { api->ReleaseSession(_encoder); }
    if (_decoder) { api->ReleaseSession(_decoder); }
    if (_sessionOptions) { api->ReleaseSessionOptions(_sessionOptions); }
    if (_memoryInfo) { api->ReleaseMemoryInfo(_memoryInfo); }
    if (_env) { api->ReleaseEnv(_env); }
}

- (nullable NSArray<NSNumber *> *)translateSourceIds:(const int64_t *)ids
                                               count:(NSInteger)count
                                               error:(NSError **)error {
    if (count <= 0) { return @[]; }

    const OrtApi* api = ortApi();

    // 所有对象在方法顶部声明，避免 goto 跳过非平凡变量初始化。
    std::vector<int64_t> sourceIds(ids, ids + count);
    std::vector<int64_t> sourceMask(count, 1);
    std::vector<int64_t> encShape = {1, static_cast<int64_t>(count)};

    OrtValue* encInputs[2] = {NULL, NULL};
    OrtValue* encOutput = NULL;
    OrtTensorTypeAndShapeInfo* encInfo = NULL;
    std::vector<float> hidden;
    int64_t srcLen = 0;
    int64_t hiddenDim = 0;

    OrtValue* decInputs[3] = {NULL, NULL, NULL};
    OrtValue* decOutput = NULL;
    OrtTensorTypeAndShapeInfo* decInfo = NULL;

    std::vector<int64_t> targetIds = {kPadToken};
    NSMutableArray<NSNumber *> *resultArr = [NSMutableArray array];
    OrtStatus* status = NULL;

    // ---- 编码器 ----
    status = api->CreateTensorWithDataAsOrtValue(
        _memoryInfo, sourceIds.data(), sourceIds.size() * sizeof(int64_t),
        encShape.data(), encShape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &encInputs[0]);
    if (status) goto done;
    status = api->CreateTensorWithDataAsOrtValue(
        _memoryInfo, sourceMask.data(), sourceMask.size() * sizeof(int64_t),
        encShape.data(), encShape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &encInputs[1]);
    if (status) goto done;

    const char* encInputNames[2] = {"input_ids", "attention_mask"};
    const char* encOutputNames[1] = {"last_hidden_state"};
    status = api->Run(_encoder, NULL, encInputNames, encInputs, 2,
                      encOutputNames, 1, &encOutput);
    if (status) goto done;

    status = api->GetTensorTypeAndShape(encOutput, &encInfo);
    if (status) goto done;
    size_t encDims = 0;
    status = api->GetDimensionsCount(encInfo, &encDims);
    if (status) goto done;
    std::vector<int64_t> encShapeOut(encDims, 0);
    status = api->GetDimensions(encInfo, encShapeOut.data(), encDims);
    if (status) goto done;
    srcLen = encShapeOut[1];
    hiddenDim = encShapeOut[2];

    float* hiddenData = NULL;
    status = api->GetTensorMutableData(encOutput, (void**)&hiddenData);
    if (status) goto done;
    hidden.assign(hiddenData, hiddenData + srcLen * hiddenDim);

    api->ReleaseTensorTypeAndShapeInfo(encInfo);
    encInfo = NULL;
    api->ReleaseValue(encOutput);
    encOutput = NULL;
    api->ReleaseValue(encInputs[0]);
    encInputs[0] = NULL;
    api->ReleaseValue(encInputs[1]);
    encInputs[1] = NULL;

    // ---- 解码器贪心循环 ----
    const char* decInputNames[3] = {"input_ids", "encoder_hidden_states", "encoder_attention_mask"};
    const char* decOutputNames[1] = {"logits"};

    for (int step = 0; step < kMaxOutputTokens; step++) {
        std::vector<int64_t> decShape = {1, static_cast<int64_t>(targetIds.size())};
        std::vector<int64_t> hiddenShape = {1, srcLen, hiddenDim};

        status = api->CreateTensorWithDataAsOrtValue(
            _memoryInfo, targetIds.data(), targetIds.size() * sizeof(int64_t),
            decShape.data(), decShape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &decInputs[0]);
        if (status) goto done;
        status = api->CreateTensorWithDataAsOrtValue(
            _memoryInfo, hidden.data(), hidden.size() * sizeof(float),
            hiddenShape.data(), hiddenShape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &decInputs[1]);
        if (status) goto done;
        status = api->CreateTensorWithDataAsOrtValue(
            _memoryInfo, sourceMask.data(), sourceMask.size() * sizeof(int64_t),
            encShape.data(), encShape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &decInputs[2]);
        if (status) goto done;

        status = api->Run(_decoder, NULL, decInputNames, decInputs, 3,
                          decOutputNames, 1, &decOutput);
        if (status) goto done;

        status = api->GetTensorTypeAndShape(decOutput, &decInfo);
        if (status) goto done;
        size_t decDims = 0;
        status = api->GetDimensionsCount(decInfo, &decDims);
        if (status) goto done;
        std::vector<int64_t> decShapeOut(decDims, 0);
        status = api->GetDimensions(decInfo, decShapeOut.data(), decDims);
        if (status) goto done;
        const int64_t tgtLen = decShapeOut[1];
        const int64_t vocabSize = decShapeOut[2];

        float* logits = NULL;
        status = api->GetTensorMutableData(decOutput, (void**)&logits);
        if (status) goto done;
        const float* row = logits + (tgtLen - 1) * vocabSize;

        int64_t best = 0;
        float bestScore = -std::numeric_limits<float>::infinity();
        for (int64_t k = 0; k < vocabSize; k++) {
            if (row[k] > bestScore) {
                bestScore = row[k];
                best = k;
            }
        }

        api->ReleaseTensorTypeAndShapeInfo(decInfo);
        decInfo = NULL;
        api->ReleaseValue(decOutput);
        decOutput = NULL;
        api->ReleaseValue(decInputs[0]);
        decInputs[0] = NULL;
        api->ReleaseValue(decInputs[1]);
        decInputs[1] = NULL;
        api->ReleaseValue(decInputs[2]);
        decInputs[2] = NULL;

        if (best == kEosToken) { break; }
        if (best != kPadToken) {
            [resultArr addObject:@(best)];
        }
        targetIds.push_back(best);
    }

done:
    if (encOutput) { api->ReleaseValue(encOutput); }
    if (encInputs[0]) { api->ReleaseValue(encInputs[0]); }
    if (encInputs[1]) { api->ReleaseValue(encInputs[1]); }
    if (decOutput) { api->ReleaseValue(decOutput); }
    if (decInputs[0]) { api->ReleaseValue(decInputs[0]); }
    if (decInputs[1]) { api->ReleaseValue(decInputs[1]); }
    if (decInputs[2]) { api->ReleaseValue(decInputs[2]); }
    if (decInfo) { api->ReleaseTensorTypeAndShapeInfo(decInfo); }

    if (status) {
        const char* msg = api->GetErrorMessage(status);
        if (error) {
            *error = [NSError errorWithDomain:@"MTTranslator" code:2
                userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithUTF8String:msg ?: "离线翻译推理失败"] }];
        }
        api->ReleaseStatus(status);
        return nil;
    }
    return resultArr;
}

@end
