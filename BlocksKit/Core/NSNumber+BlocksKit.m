//!
//  NSNumber+BlocksKit.m
//  BlocksKit
//

#import "NSNumber+BlocksKit.h"

@implementation NSNumber (BlocksKit)

/// 执行N此block N是self的值
- (void)bk_times:(void (^)())block
{
  NSParameterAssert(block != nil);

  for (NSInteger idx = 0 ; idx < self.integerValue ; ++idx ) {
    block();
  }
}

@end
