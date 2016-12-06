//!
//  NSObject+A2DynamicDelegate.m
//  BlocksKit
//

#import "NSObject+A2DynamicDelegate.h"
@import ObjectiveC.runtime;
#import "A2DynamicDelegate.h"

extern Protocol *a2_dataSourceProtocol(Class cls);
extern Protocol *a2_delegateProtocol(Class cls);

/// 返回A2DynamicDelegate子类或者A2DynamicDelegate A2DynamicUITableViewDelegate
static Class a2_dynamicDelegateClass(Class cls, NSString *suffix)
{
	while (cls) {
		NSString *className = [NSString stringWithFormat:@"A2Dynamic%@%@", NSStringFromClass(cls), suffix];
		Class ddClass = NSClassFromString(className);
		if (ddClass) return ddClass;

		cls = class_getSuperclass(cls);
	}

	return [A2DynamicDelegate class];
}

/// 串行队列
static dispatch_queue_t a2_backgroundQueue(void)
{
	static dispatch_once_t onceToken;
	static dispatch_queue_t backgroundQueue = nil;
	dispatch_once(&onceToken, ^{
		backgroundQueue = dispatch_queue_create("BlocksKit.DynamicDelegate.Queue", DISPATCH_QUEUE_SERIAL);
	});
	return backgroundQueue;
}

@implementation NSObject (A2DynamicDelegate)
/// UITableView -> UITableViewDataSource
- (id)bk_dynamicDataSource
{
	Protocol *protocol = a2_dataSourceProtocol([self class]);
	Class class = a2_dynamicDelegateClass([self class], @"DataSource");
	return [self bk_dynamicDelegateWithClass:class forProtocol:protocol];
}


/// 创建对应A2DynamicDelegate的实例或其子类实例
- (id)bk_dynamicDelegate
{
    // UIAlertView -> UIAlertViewDelegate
	Protocol *protocol = a2_delegateProtocol([self class]);
    // A2DynamicDelegate或子类
	Class class = a2_dynamicDelegateClass([self class], @"Delegate");
    
	return [self bk_dynamicDelegateWithClass:class forProtocol:protocol];
}

/// protocol: UIActionSheetDelegate 返回A2DynamicUIActionSheetDelegate实例
/// 如果没有会创建并通过关联对象绑定
- (id)bk_dynamicDelegateForProtocol:(Protocol *)protocol
{
    // 根据protocol类型获取A2DynamicDelegate的子类 如UIActionSheetDelegate -> A2DynamicUIActionSheetDelegate
	Class class = [A2DynamicDelegate class];
	NSString *protocolName = NSStringFromProtocol(protocol);
	if ([protocolName hasSuffix:@"Delegate"]) {
		class = a2_dynamicDelegateClass([self class], @"Delegate");
	} else if ([protocolName hasSuffix:@"DataSource"]) {
		class = a2_dynamicDelegateClass([self class], @"DataSource");
	}

	return [self bk_dynamicDelegateWithClass:class forProtocol:protocol];
}

/// 创建A2DynamicDelegate实例 cls是A2DynamicDelegate子类
/// 使用协议作为key 将创建的实例跟对象关联
/// 一种情况 cls: A2DynamicUIActionSheetDelegate protocol: UIActionSheetDelegate
/// 返回A2DynamicUIActionSheetDelegate实例 无则创建
- (id)bk_dynamicDelegateWithClass:(Class)cls forProtocol:(Protocol *)protocol
{
	/**
	 * Storing the dynamic delegate as an associated object of the delegating
	 * object not only allows us to later retrieve the delegate, but it also
	 * creates a strong relationship to the delegate. Since delegates are weak
	 * references on the part of the delegating object, a dynamic delegate
	 * would be deallocated immediately after its declaring scope ends.
	 * Therefore, this strong relationship is required to ensure that the
	 * delegate's lifetime is at least as long as that of the delegating object.
	 **/

	__block A2DynamicDelegate *dynamicDelegate;

    /// 在串行队列中执行
	dispatch_sync(a2_backgroundQueue(), ^{
		dynamicDelegate = objc_getAssociatedObject(self, (__bridge const void *)protocol);

		if (!dynamicDelegate)
		{
			dynamicDelegate = [[cls alloc] initWithProtocol:protocol];
			objc_setAssociatedObject(self, (__bridge const void *)protocol, dynamicDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
	});

	return dynamicDelegate;
}

@end
