#import "MTTranslator.h"

#include <onnxruntime/onnxruntime_c_api.h>

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static const int64_t kPadToken = 65000;
static const int64_t kEosToken = 0;
static const int kMaxOutputTokens = 64;
#define kTargetCapacity 65

static const OrtApi* ortApi(void) {
    return OrtGetApiBase()->GetApi(ORT_API_VERSION);
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

    int64_t* sourceIds = (int64_t*)malloc((size_t)count * sizeof(int64_t));
    int64_t* sourceMask = (int64_t*)malloc((size_t)count * sizeof(int64_t));
    if (!sourceIds || !sourceMask) {
        free(sourceIds); free(sourceMask);
        if (error) { *error = [NSError errorWithDomain:@"MTTranslator" code:2
            userInfo:@{ NSLocalizedDescriptionKey: @"内存不足" }]; }
        return nil;
    }
    memcpy(sourceIds, ids, (size_t)count * sizeof(int64_t));
    for (NSInteger i = 0; i < count; i++) { sourceMask[i] = 1; }

    int64_t encShape[2] = {1, (int64_t)count};

    OrtValue* encInputs[2] = {NULL, NULL};
    OrtValue* encOutput = NULL;
    OrtTensorTypeAndShapeInfo* encInfo = NULL;
    float* hidden = NULL;
    int64_t srcLen = 0;
    int64_t hiddenDim = 0;

    OrtValue* decInputs[3] = {NULL, NULL, NULL};
    OrtValue* decOutput = NULL;
    OrtTensorTypeAndShapeInfo* decInfo = NULL;

    int64_t targetIds[kTargetCapacity];
    int targetLen = 1;
    targetIds[0] = kPadToken;
    NSMutableArray<NSNumber *> *resultArr = [NSMutableArray array];
    OrtStatus* status = NULL;

    // ---- 编码器 ----
    status = api->CreateTensorWithDataAsOrtValue(
        _memoryInfo, sourceIds, (size_t)count * sizeof(int64_t),
        encShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &encInputs[0]);
    if (status) goto done;
    status = api->CreateTensorWithDataAsOrtValue(
        _memoryInfo, sourceMask, (size_t)count * sizeof(int64_t),
        encShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &encInputs[1]);
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
    int64_t encShapeOut[3] = {0, 0, 0};
    size_t readDims = encDims < 3 ? encDims : 3;
    status = api->GetDimensions(encInfo, encShapeOut, readDims);
    if (status) goto done;
    srcLen = encShapeOut[1];
    hiddenDim = encShapeOut[2];

    float* hiddenData = NULL;
    status = api->GetTensorMutableData(encOutput, (void**)&hiddenData);
    if (status) goto done;
    size_t hiddenCount = (size_t)(srcLen * hiddenDim);
    hidden = (float*)malloc(hiddenCount * sizeof(float));
    if (!hidden) {
        free(sourceIds); free(sourceMask);
        if (error) { *error = [NSError errorWithDomain:@"MTTranslator" code:2
            userInfo:@{ NSLocalizedDescriptionKey: @"内存不足" }]; }
        return nil;
    }
    memcpy(hidden, hiddenData, hiddenCount * sizeof(float));

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
        int64_t decShape[2] = {1, (int64_t)targetLen};
        int64_t hiddenShape[3] = {1, srcLen, hiddenDim};

        status = api->CreateTensorWithDataAsOrtValue(
            _memoryInfo, targetIds, (size_t)targetLen * sizeof(int64_t),
            decShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &decInputs[0]);
        if (status) goto done;
        status = api->CreateTensorWithDataAsOrtValue(
            _memoryInfo, hidden, hiddenCount * sizeof(float),
            hiddenShape, 3, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &decInputs[1]);
        if (status) goto done;
        status = api->CreateTensorWithDataAsOrtValue(
            _memoryInfo, sourceMask, (size_t)count * sizeof(int64_t),
            encShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &decInputs[2]);
        if (status) goto done;

        status = api->Run(_decoder, NULL, decInputNames, decInputs, 3,
                          decOutputNames, 1, &decOutput);
        if (status) goto done;

        status = api->GetTensorTypeAndShape(decOutput, &decInfo);
        if (status) goto done;
        size_t decDims = 0;
        status = api->GetDimensionsCount(decInfo, &decDims);
        if (status) goto done;
        int64_t decShapeOut[3] = {0, 0, 0};
        size_t decRead = decDims < 3 ? decDims : 3;
        status = api->GetDimensions(decInfo, decShapeOut, decRead);
        if (status) goto done;
        const int64_t tgtLen = decShapeOut[1];
        const int64_t vocabSize = decShapeOut[2];

        float* logits = NULL;
        status = api->GetTensorMutableData(decOutput, (void**)&logits);
        if (status) goto done;
        const float* row = logits + (tgtLen - 1) * vocabSize;

        int64_t best = 0;
        float bestScore = -1e30f;
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
        if (targetLen < kTargetCapacity) {
            targetIds[targetLen++] = best;
        } else {
            break;
        }
    }

done:
    free(sourceIds);
    free(sourceMask);
    free(hidden);
    if (encOutput) { api->ReleaseValue(encOutput); }
    if (encInputs[0]) { api->ReleaseValue(encInputs[0]); }
    if (encInputs[1]) { api->ReleaseValue(encInputs[1]); }
    if (decOutput) { api->ReleaseValue(decOutput); }
    if (decInputs[0]) { api->ReleaseValue(decInputs[0]); }
    if (decInputs[1]) { api->ReleaseValue(decInputs[1]); }
    if (decInputs[2]) { api->ReleaseValue(decInputs[2]); }
    if (encInfo) { api->ReleaseTensorTypeAndShapeInfo(encInfo); }
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
