//
//  NSObject+A2BlockDelegate.m
//  BlocksKit
//

#import "NSObject+A2BlockDelegate.h"
@import ObjectiveC.message;
#import "A2DynamicDelegate.h"
#import "NSObject+A2DynamicDelegate.h"

#pragma mark - Declarations and macros

extern Protocol *a2_dataSourceProtocol(Class cls);
extern Protocol *a2_delegateProtocol(Class cls);

#pragma mark - Functions

/// 没必要重写吧。。。
static BOOL bk_object_isKindOfClass(id obj, Class testClass)
{
	BOOL isKindOfClass = NO;
	Class cls = object_getClass(obj);
	while (cls && !isKindOfClass) {
		isKindOfClass = (cls == testClass);
		cls = class_getSuperclass(cls);
	}

	return isKindOfClass;
}

static Protocol *a2_protocolForDelegatingObject(id obj, Protocol *protocol)
{
	NSString *protocolName = NSStringFromProtocol(protocol);
	if ([protocolName hasSuffix:@"Delegate"]) {
		Protocol *p = a2_delegateProtocol([obj class]);
		if (p) return p;
	} else if ([protocolName hasSuffix:@"DataSource"]) {
		Protocol *p = a2_dataSourceProtocol([obj class]);
		if (p) return p;
	}

	return protocol;
}

static inline BOOL isValidIMP(IMP impl) {
#if defined(__arm64__)
    if (impl == NULL || impl == _objc_msgForward) return NO;
#else
    if (impl == NULL || impl == _objc_msgForward || impl == (IMP)_objc_msgForward_stret) return NO;
#endif
    return YES;
}

/// 给cls添加实现
/// 如果已有oldSel的实现 返回NO
/// 如果父类有oldSel实现
/// 1.如果aggressive 添加newSel指向父类实现
/// 2.否则oldSel指向父类实现 newSel指向newIMP
static BOOL addMethodWithIMP(Class cls, SEL oldSel, SEL newSel, IMP newIMP, const char *types, BOOL aggressive) {
    // 如果已有oldSel的实现
	if (!class_addMethod(cls, oldSel, newIMP, types)) {
		return NO;
	}

	// We just ended up implementing a method that doesn't exist
	// (-[NSURLConnection setDelegate:]) or overrode a superclass
	// version (-[UIImagePickerController setDelegate:]).
    // 查找父类oldSel实现
	IMP parentIMP = NULL;
	Class superclass = class_getSuperclass(cls);
	while (superclass && !isValidIMP(parentIMP)) {
		parentIMP = class_getMethodImplementation(superclass, oldSel);
		if (isValidIMP(parentIMP)) {
			break;
		} else {
			parentIMP = NULL;
		}

		superclass = class_getSuperclass(superclass);
	}

	if (parentIMP) {
		if (aggressive) {
			return class_addMethod(cls, newSel, parentIMP, types);
		}

		class_replaceMethod(cls, newSel, newIMP, types);
		class_replaceMethod(cls, oldSel, parentIMP, types);
	}

	return YES;
}

static BOOL swizzleWithIMP(Class cls, SEL oldSel, SEL newSel, IMP newIMP, const char *types, BOOL aggressive) {
    Method origMethod = class_getInstanceMethod(cls, oldSel);

	if (addMethodWithIMP(cls, oldSel, newSel, newIMP, types, aggressive)) {
		return YES;
	}

	// common case, actual swap
	BOOL ret = class_addMethod(cls, newSel, newIMP, types);
	Method newMethod = class_getInstanceMethod(cls, newSel);
	method_exchangeImplementations(origMethod, newMethod);
	return ret;
}

/// @selector(prefix_Key_suffix)
static SEL selectorWithPattern(const char *prefix, const char *key, const char *suffix) {
	size_t prefixLength = prefix ? strlen(prefix) : 0;
	size_t suffixLength = suffix ? strlen(suffix) : 0;

	char initial = key[0];
	if (prefixLength) initial = (char)toupper(initial);
	size_t initialLength = 1;

	const char *rest = key + initialLength;
	size_t restLength = strlen(rest);

	char selector[prefixLength + initialLength + restLength + suffixLength + 1];
	memcpy(selector, prefix, prefixLength);
	selector[prefixLength] = initial;
	memcpy(selector + prefixLength + initialLength, rest, restLength);
	memcpy(selector + prefixLength + initialLength + restLength, suffix, suffixLength);
	selector[prefixLength + initialLength + restLength + suffixLength] = '\0';

	return sel_registerName(selector);
}

/// 返回属性对应的getter SEL
/// 有自定义的Getter则返回 无则返回属性名
static SEL getterForProperty(objc_property_t property, const char *name)
{
	if (property) {
		char *getterName = property_copyAttributeValue(property, "G");
		if (getterName) {
			SEL getter = sel_getUid(getterName);
			free(getterName);
			if (getter) return getter;
		}
	}

	const char *propertyName = property ? property_getName(property) : name;
	return sel_registerName(propertyName);
}

/// setter SEL
static SEL setterForProperty(objc_property_t property, const char *name)
{
	if (property) {
		char *setterName = property_copyAttributeValue(property, "S");
		if (setterName) {
			SEL setter = sel_getUid(setterName);
			free(setterName);
			if (setter) return setter;
		}
	}

	const char *propertyName = property ? property_getName(property) : name;
	return selectorWithPattern("set", propertyName, ":");
}

/// a2_original
static inline SEL prefixedSelector(SEL original) {
	return selectorWithPattern("a2_", sel_getName(original), NULL);
}

#pragma mark -

typedef struct {
	SEL setter;
	SEL a2_setter;
	SEL getter;
} A2BlockDelegateInfo;

static NSUInteger A2BlockDelegateInfoSize(const void *__unused item) {
	return sizeof(A2BlockDelegateInfo);
}

static NSString *A2BlockDelegateInfoDescribe(const void *__unused item) {
	if (!item) { return nil; }
	const A2BlockDelegateInfo *info = item;
	return [NSString stringWithFormat:@"(setter: %s, getter: %s)", sel_getName(info->setter), sel_getName(info->getter)];
}

/// 设置A2DynamicUIActionSheetDelegate实例为自己的代理并返回
/// 例：protocol为UIActionSheetDelegate时返回A2DynamicUIActionSheetDelegate实例
/// info内存放delegate的setter和getter信息
static inline A2DynamicDelegate *getDynamicDelegate(NSObject *delegatingObject, Protocol *protocol, const A2BlockDelegateInfo *info, BOOL ensuring) {
    
	A2DynamicDelegate *dynamicDelegate = [delegatingObject bk_dynamicDelegateForProtocol:a2_protocolForDelegatingObject(delegatingObject, protocol)];

	if (!info || !info->setter || !info->getter) {
		return dynamicDelegate;
	}

    // !info->setter如果成立 上面就先返回了
	if (!info->a2_setter && !info->setter) { return dynamicDelegate; }

    // 获取代理
	id (*getterDispatch)(id, SEL) = (id (*)(id, SEL)) objc_msgSend;
	id originalDelegate = getterDispatch(delegatingObject, info->getter);

    // 如果已经是dynamicDelegate 返回
	if (bk_object_isKindOfClass(originalDelegate, A2DynamicDelegate.class)) { return dynamicDelegate; }

    // 调用这个方法的时候 setDelegate已经被hook了 调用a2_setter相当于调用原实现
	void (*setterDispatch)(id, SEL, id) = (void (*)(id, SEL, id)) objc_msgSend;
	setterDispatch(delegatingObject, info->a2_setter ?: info->setter, dynamicDelegate);

	return dynamicDelegate;
}

typedef A2DynamicDelegate *(^A2GetDynamicDelegateBlock)(NSObject *, BOOL);

@interface A2DynamicDelegate ()

@property (nonatomic, weak, readwrite) id realDelegate;

@end

#pragma mark -

@implementation NSObject (A2BlockDelegate)

#pragma mark Helpers

/// 返回一个NSMapTable 值类型是A2BlockDelegateInfo key是protocol
/// createIfNeeded 没有的话是否创建
/// 类持有一个NSMapTable来存放协议与对应的A2BlockDelegateInfo 比如UIActionSheet 存放协议A2DynamicUIActionSheetDelegate对应信息
+ (NSMapTable *)bk_delegateInfoByProtocol:(BOOL)createIfNeeded
{
	NSMapTable *delegateInfo = objc_getAssociatedObject(self, _cmd);
	if (delegateInfo || !createIfNeeded) { return delegateInfo; }

    // NSPointerFunctionsMallocMemory对key进行拷贝
	NSPointerFunctions *protocols = [NSPointerFunctions pointerFunctionsWithOptions:NSPointerFunctionsOpaqueMemory|NSPointerFunctionsObjectPointerPersonality];
	NSPointerFunctions *infoStruct = [NSPointerFunctions pointerFunctionsWithOptions:NSPointerFunctionsMallocMemory|NSPointerFunctionsStructPersonality|NSPointerFunctionsCopyIn];
	infoStruct.sizeFunction = A2BlockDelegateInfoSize;
	infoStruct.descriptionFunction = A2BlockDelegateInfoDescribe;

	delegateInfo = [[NSMapTable alloc] initWithKeyPointerFunctions:protocols valuePointerFunctions:infoStruct capacity:0];
	objc_setAssociatedObject(self, _cmd, delegateInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	return delegateInfo;
}

/// 往上遍历父类查找 只查找不创建
+ (const A2BlockDelegateInfo *)bk_delegateInfoForProtocol:(Protocol *)protocol
{
	A2BlockDelegateInfo *infoAsPtr = NULL;
	Class cls = self;
	while ((infoAsPtr == NULL || infoAsPtr->getter == NULL) && cls != nil && cls != NSObject.class) {
		NSMapTable *map = [cls bk_delegateInfoByProtocol:NO];
		infoAsPtr = (__bridge void *)[map objectForKey:protocol];
		cls = [cls superclass];
	}
	NSCAssert(infoAsPtr != NULL, @"Class %@ not assigned dynamic delegate for protocol %@", NSStringFromClass(self), NSStringFromProtocol(protocol));
	return infoAsPtr;
}

#pragma mark Linking block properties

+ (void)bk_linkDataSourceMethods:(NSDictionary *)dictionary
{
	[self bk_linkProtocol:a2_dataSourceProtocol(self) methods:dictionary];
}

+ (void)bk_linkDelegateMethods:(NSDictionary *)dictionary
{
	[self bk_linkProtocol:a2_delegateProtocol(self) methods:dictionary];
}

/// dictionary存放propertyName:selectorName
/// protocol用来查找对应的A2BlockDelegateInfo
/// 通过A2BlockDelegateInfo找到A2DynamicDelegate
/// A2DynamicDelegate中有对应setter getter的实现
/// 在类上添加setter getter方法
/* 
UIActionSheetDelegate 
@{
 @"bk_willShowBlock": @"willPresentActionSheet:",
 @"bk_didShowBlock": @"didPresentActionSheet:",
 @"bk_willDismissBlock": @"actionSheet:willDismissWithButtonIndex:",
 @"bk_didDismissBlock": @"actionSheet:didDismissWithButtonIndex:"
}
*/
+ (void)bk_linkProtocol:(Protocol *)protocol methods:(NSDictionary *)dictionary
{
	[dictionary enumerateKeysAndObjectsUsingBlock:^(NSString *propertyName, NSString *selectorName, BOOL *stop) {
		const char *name = propertyName.UTF8String;
		objc_property_t property = class_getProperty(self, name);
		NSCAssert(property, @"Property \"%@\" does not exist on class %s", propertyName, class_getName(self));

		char *dynamic = property_copyAttributeValue(property, "D");
		NSCAssert2(dynamic, @"Property \"%@\" on class %s must be backed with \"@dynamic\"", propertyName, class_getName(self));
		free(dynamic);

		char *copy = property_copyAttributeValue(property, "C");
		NSCAssert2(copy, @"Property \"%@\" on class %s must be defined with the \"copy\" attribute", propertyName, class_getName(self));
		free(copy);

		SEL selector = NSSelectorFromString(selectorName);
		SEL getter = getterForProperty(property, name);
		SEL setter = setterForProperty(property, name);

        // 已存在setter或者getter 返回
		if (class_respondsToSelector(self, setter) || class_respondsToSelector(self, getter)) { return; }

        
		const A2BlockDelegateInfo *info = [self bk_delegateInfoForProtocol:protocol];

        // 添加getter
		IMP getterImplementation = imp_implementationWithBlock(^(NSObject *delegatingObject) {
			A2DynamicDelegate *delegate = getDynamicDelegate(delegatingObject, protocol, info, NO);
			return [delegate blockImplementationForMethod:selector];
		});

		if (!class_addMethod(self, getter, getterImplementation, "@@:")) {
			NSCAssert(NO, @"Could not implement getter for \"%@\" property.", propertyName);
		}

        // 添加setter
		IMP setterImplementation = imp_implementationWithBlock(^(NSObject *delegatingObject, id block) {
			A2DynamicDelegate *delegate = getDynamicDelegate(delegatingObject, protocol, info, YES);
			[delegate implementMethod:selector withBlock:block];
		});

		if (!class_addMethod(self, setter, setterImplementation, "v@:@")) {
			NSCAssert(NO, @"Could not implement setter for \"%@\" property.", propertyName);
		}
	}];
}

#pragma mark Dynamic Delegate Replacement

+ (void)bk_registerDynamicDataSource
{
	[self bk_registerDynamicDelegateNamed:@"dataSource" forProtocol:a2_dataSourceProtocol(self)];
}
+ (void)bk_registerDynamicDelegate
{
	[self bk_registerDynamicDelegateNamed:@"delegate" forProtocol:a2_delegateProtocol(self)];
}

+ (void)bk_registerDynamicDataSourceNamed:(NSString *)dataSourceName
{
	[self bk_registerDynamicDelegateNamed:dataSourceName forProtocol:a2_dataSourceProtocol(self)];
}
+ (void)bk_registerDynamicDelegateNamed:(NSString *)delegateName
{
	[self bk_registerDynamicDelegateNamed:delegateName forProtocol:a2_delegateProtocol(self)];
}

/// 就是将协议对应的A2BlockDelegateInfo储存起来
/// 以UIActionSheet为例
/// delegateName: @"delegate"
/// protocol: UIActionSheetDelegate
/// hook setDelegate 将代理设置为A2DynamicUIActionSheetDelegate实例 并持有relDelegate
+ (void)bk_registerDynamicDelegateNamed:(NSString *)delegateName forProtocol:(Protocol *)protocol
{
	NSMapTable *propertyMap = [self bk_delegateInfoByProtocol:YES];
	A2BlockDelegateInfo *infoAsPtr = (__bridge void *)[propertyMap objectForKey:protocol];
    // 已储存就返回
	if (infoAsPtr != NULL) { return; }

    // 未储存的话 创建A2BlockDelegateInfo并储存
	const char *name = delegateName.UTF8String;
	objc_property_t property = class_getProperty(self, name);
	SEL setter = setterForProperty(property, name);
	SEL a2_setter = prefixedSelector(setter);
	SEL getter = getterForProperty(property, name);

	A2BlockDelegateInfo info = {
		setter, a2_setter, getter
	};

    // propertyMap对info进行了copy-in
    // 所以下面infoAsPtr重新获取
	[propertyMap setObject:(__bridge id)&info forKey:protocol];
	infoAsPtr = (__bridge void *)[propertyMap objectForKey:protocol];

    /// hook setter方法 将delegate赋给dynamicDelegate的realDelegate
	IMP setterImplementation = imp_implementationWithBlock(^(NSObject *delegatingObject, id delegate) {
        /// 将代理设置为A2DynamicUIActionSheetDelegate实例
		A2DynamicDelegate *dynamicDelegate = getDynamicDelegate(delegatingObject, protocol, infoAsPtr, YES);
		if ([delegate isEqual:dynamicDelegate]) {
			delegate = nil;
		}
		dynamicDelegate.realDelegate = delegate;
	});
	if (!swizzleWithIMP(self, setter, a2_setter, setterImplementation, "v@:@", YES)) {
		bzero(infoAsPtr, sizeof(A2BlockDelegateInfo));
		return;
	}

	if (![self instancesRespondToSelector:getter]) { // 如果没实现getter 添加实现
		IMP getterImplementation = imp_implementationWithBlock(^(NSObject *delegatingObject) {
			return [delegatingObject bk_dynamicDelegateForProtocol:a2_protocolForDelegatingObject(delegatingObject, protocol)];
		});

		addMethodWithIMP(self, getter, NULL, getterImplementation, "@@:", NO);
	}
}

- (id)bk_ensuredDynamicDelegate
{
	Protocol *protocol = a2_delegateProtocol(self.class);
	return [self bk_ensuredDynamicDelegateForProtocol:protocol];
}

- (id)bk_ensuredDynamicDelegateForProtocol:(Protocol *)protocol
{
	const A2BlockDelegateInfo *info = [self.class bk_delegateInfoForProtocol:protocol];
	return getDynamicDelegate(self, protocol, info, YES);
}

@end
