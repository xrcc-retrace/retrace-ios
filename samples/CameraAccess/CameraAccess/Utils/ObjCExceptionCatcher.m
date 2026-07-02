#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block
                 error:(NSError **)error {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error) {
      NSMutableDictionary *info = [NSMutableDictionary dictionary];
      info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
      info[@"NSExceptionName"] = exception.name;
      *error = [NSError errorWithDomain:@"ObjCExceptionCatcher"
                                   code:1
                               userInfo:info];
    }
    return NO;
  }
}

@end
