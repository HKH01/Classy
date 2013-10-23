//
//  CASStyler.m
//  Classy
//
//  Created by Jonas Budelmann on 16/09/13.
//  Copyright (c) 2013 cloudling. All rights reserved.
//

#import "CASStyler.h"
#import "CASParser.h"
#import "CASStyleSelector.h"
#import "CASPropertyDescriptor.h"
#import "UIView+CASAdditions.h"
#import "UITextField+CASAdditions.h"
#import "CASUtilities.h"

@interface CASStyler ()

@property (nonatomic, strong) NSMutableArray *styles;
@property (nonatomic, strong) NSMapTable *viewClassDescriptorCache;

@end

@implementation CASStyler

+ (instancetype)defaultStyler {
    static CASStyler * _defaultStyler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _defaultStyler = CASStyler.new;
    });
    
    return _defaultStyler;
}

- (id)init {
    self = [super init];
    if (!self) return nil;

    self.viewClassDescriptorCache = NSMapTable.strongToStrongObjectsMapTable;
    [self setupViewClassDescriptors];

    return self;
}

- (void)styleView:(UIView *)view {
    if (!self.filePath) {
        // load default style file
        self.filePath = [[NSBundle mainBundle] pathForResource:@"stylesheet.cas" ofType:nil];
    }
    // TODO style lookup table to improve speed.

    for (CASStyleSelector *styleSelector in self.styles.reverseObjectEnumerator) {
        if ([styleSelector shouldSelectView:view]) {
            // apply style nodes
            for (CASStyleProperty *styleProperty in styleSelector.node.properties) {
                [styleProperty.invocation invokeWithTarget:view];
            }
        }
    }
}

- (void)setFilePath:(NSString *)filePath {
    NSError *error = nil;
    [self setFilePath:filePath error:&error];
    if (error) {
        CASLog(@"Error: %@", error);
    }
}

- (void)setFilePath:(NSString *)filePath error:(NSError **)error {
    if ([_filePath isEqualToString:filePath]) return;
    _filePath = filePath;

    self.styles = [[CASParser stylesFromFilePath:filePath error:error] mutableCopy];
    if (!self.styles.count) {
        return;
    }

    // order descending by precedence
    [self.styles sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(CASStyleSelector *s1, CASStyleSelector *s2) {
        if (s1.precedence == s2.precedence) return NSOrderedSame;
        if (s1.precedence <  s2.precedence) return NSOrderedDescending;
        return NSOrderedAscending;
    }];

    // precompute values
    for (CASStyleSelector *styleSelector in self.styles.reverseObjectEnumerator) {
        for (CASStyleProperty *styleProperty in styleSelector.node.properties) {
            // TODO type checking and throw errors

            // ensure we dont do same node twice
            if (styleProperty.invocation) continue;
            NSInvocation *invocation = [self invocationForClass:styleSelector.viewClass styleProperty:styleProperty];
            styleProperty.invocation = invocation;
        }
    }
}

#pragma mark - private

- (NSInvocation *)invocationForClass:(Class)class styleProperty:(CASStyleProperty *)styleProperty {
    CASViewClassDescriptor *viewClassDescriptor = [self viewClassDescriptorForClass:class];
    CASPropertyDescriptor *propertyDescriptor = [viewClassDescriptor propertyDescriptorForKey:styleProperty.name];

    NSInvocation *invocation = [viewClassDescriptor invocationForPropertyDescriptor:propertyDescriptor];
    [invocation retainArguments];
    [propertyDescriptor.argumentDescriptors enumerateObjectsUsingBlock:^(CASArgumentDescriptor *argDescriptor, NSUInteger idx, BOOL *stop) {
        NSInteger argIndex = 2 + idx;
        switch (argDescriptor.primitiveType) {
            case CASPrimitiveTypeBOOL: {
                BOOL value = [[styleProperty valueOfTokenType:CASTokenTypeBoolean] boolValue];
                [invocation setArgument:&value atIndex:argIndex];
                break;
            }
            case CASPrimitiveTypeInteger: {
                NSInteger value;
                if (argDescriptor.valuesByName) {
                    NSString *valueName = [styleProperty valueOfTokenType:CASTokenTypeRef];
                    value = [argDescriptor.valuesByName[valueName] integerValue];
                } else {
                    value = [[styleProperty valueOfTokenType:CASTokenTypeUnit] integerValue];
                }
                [invocation setArgument:&value atIndex:argIndex];
                break;
            }
            case CASPrimitiveTypeDouble: {
                CGFloat value = [[styleProperty valueOfTokenType:CASTokenTypeUnit] doubleValue];
                [invocation setArgument:&value atIndex:argIndex];
                break;
            }
            case CASPrimitiveTypeCGSize: {
                CGSize size;
                [styleProperty transformValuesToCGSize:&size];
                [invocation setArgument:&size atIndex:argIndex];
                break;
            }
            case CASPrimitiveTypeUIEdgeInsets: {
                UIEdgeInsets insets;
                [styleProperty transformValuesToUIEdgeInsets:&insets];
                [invocation setArgument:&insets atIndex:argIndex];
                break;
            }
            default:
                break;
        }

        if (argDescriptor.argumentClass == UIImage.class) {
            UIImage *image = nil;
            [styleProperty transformValuesToUIImage:&image];
            [invocation setArgument:&image atIndex:argIndex];
        } else if (argDescriptor.argumentClass  == UIColor.class) {
            UIColor *color = nil;
            [styleProperty transformValuesToUIColor:&color];
            [invocation setArgument:&color atIndex:argIndex];
        } else if (argDescriptor.argumentClass) {
            id firstValue = styleProperty.values.count ? styleProperty.values[0] : nil;
            [invocation setArgument:&firstValue atIndex:argIndex];
        }
    }];
    return invocation;
}

- (void)setupViewClassDescriptors {
    // UIView
    CASViewClassDescriptor *viewClassDescriptor = [self viewClassDescriptorForClass:UIView.class];
    viewClassDescriptor.propertyKeyAliases = @{
        @"borderColor"   : @cas_propertykey(UIView, cas_borderColor),
        @"borderWidth"   : @cas_propertykey(UIView, cas_borderWidth),
        @"borderRadius"  : @cas_propertykey(UIView, cas_cornerRadius),
        @"shadowColor"   : @cas_propertykey(UIView, cas_shadowColor),
        @"shadowOffset"  : @cas_propertykey(UIView, cas_shadowOffset),
        @"shadowOpacity" : @cas_propertykey(UIView, cas_shadowOpacity),
        @"shadowRadius"  : @cas_propertykey(UIView, cas_shadowRadius),
    };

    NSDictionary *contentModeMap = @{
        @"fill"        : @(UIViewContentModeScaleToFill),
        @"aspectFit"   : @(UIViewContentModeScaleAspectFit),
        @"aspectFill"  : @(UIViewContentModeScaleAspectFill),
        @"redraw"      : @(UIViewContentModeRedraw),
        @"center"      : @(UIViewContentModeCenter),
        @"top"         : @(UIViewContentModeTop),
        @"bottom"      : @(UIViewContentModeBottom),
        @"left"        : @(UIViewContentModeLeft),
        @"right"       : @(UIViewContentModeRight),
        @"topLeft"     : @(UIViewContentModeTopLeft),
        @"topRight"    : @(UIViewContentModeTopRight),
        @"bottomLeft"  : @(UIViewContentModeBottomLeft),
        @"bottomRight" : @(UIViewContentModeBottomRight),
    };
    [viewClassDescriptor setPropertyType:[CASArgumentDescriptor argWithValuesByName:contentModeMap]
                                  forKey:@cas_propertykey(UIView, contentMode)];

    // some properties don't show up via reflection so we need to add them manually
    [viewClassDescriptor setPropertyType:[CASArgumentDescriptor argWithClass:UIColor.class]
                                  forKey:@cas_propertykey(UIView, backgroundColor)];

    // UITextField
    // TODO text insets
    // TODO border insets
    viewClassDescriptor = [self viewClassDescriptorForClass:UITextField.class];
    viewClassDescriptor.propertyKeyAliases = @{
        @"fontColor"           : @cas_propertykey(UITextField, textColor),
        @"fontName"            : @cas_propertykey(UITextField, cas_fontName),
        @"fontSize"            : @cas_propertykey(UITextField, cas_fontSize),
        @"horizontalAlignment" : @cas_propertykey(UITextField, textAlignment),
        @"backgroundImage"     : @cas_propertykey(UITextField, background),
        @"textInsets"          : @cas_propertykey(UITextField, cas_textEdgeInsets),
    };

    NSDictionary *textAlignmentMap = @{
        @"center"    : @(NSTextAlignmentCenter),
        @"left"      : @(NSTextAlignmentLeft),
        @"right"     : @(NSTextAlignmentRight),
        @"justified" : @(NSTextAlignmentJustified),
        @"natural"   : @(NSTextAlignmentNatural),
    };
    [viewClassDescriptor setPropertyType:[CASArgumentDescriptor argWithValuesByName:textAlignmentMap]
                                  forKey:@cas_propertykey(UITextField, textAlignment)];

    NSDictionary *borderStyleMap = @{
        @"none"    : @(UITextBorderStyleNone),
        @"line"    : @(UITextBorderStyleLine),
        @"bezel"   : @(UITextBorderStyleBezel),
        @"rounded" : @(UITextBorderStyleRoundedRect),
    };
    [viewClassDescriptor setPropertyType:[CASArgumentDescriptor argWithValuesByName:borderStyleMap]
                                  forKey:@cas_propertykey(UITextField, borderStyle)];

    
    // UIControl
    viewClassDescriptor = [self viewClassDescriptorForClass:UIControl.class];

    NSDictionary *contentVerticalAlignmentMap = @{
        @"center" : @(UIControlContentVerticalAlignmentCenter),
        @"top"    : @(UIControlContentVerticalAlignmentTop),
        @"bottom" : @(UIControlContentVerticalAlignmentBottom),
        @"fill"   : @(UIControlContentVerticalAlignmentFill),
    };
    [viewClassDescriptor setPropertyType:[CASArgumentDescriptor argWithValuesByName:contentVerticalAlignmentMap]
                                  forKey:@cas_propertykey(UIControl, contentVerticalAlignment)];

    NSDictionary *contentHorizontalAlignmentMap = @{
        @"center" : @(UIControlContentHorizontalAlignmentCenter),
        @"left"   : @(UIControlContentHorizontalAlignmentLeft),
        @"right"  : @(UIControlContentHorizontalAlignmentRight),
        @"fill"   : @(UIControlContentHorizontalAlignmentFill),
    };
    [viewClassDescriptor setPropertyType:[CASArgumentDescriptor argWithValuesByName:contentHorizontalAlignmentMap]
                                  forKey:@cas_propertykey(UIControl, contentHorizontalAlignment)];
}

- (CASViewClassDescriptor *)viewClassDescriptorForClass:(Class)class {
    CASViewClassDescriptor *viewClassDescriptor = [self.viewClassDescriptorCache objectForKey:class];
    if (!viewClassDescriptor) {
        viewClassDescriptor = [[CASViewClassDescriptor alloc] initWithClass:class];
        if (class.superclass && ![UIResponder.class isSubclassOfClass:class.superclass]) {
            viewClassDescriptor.parent = [self viewClassDescriptorForClass:class.superclass];
        }
        [self.viewClassDescriptorCache setObject:viewClassDescriptor forKey:class];
    }
    return viewClassDescriptor;
}

#pragma mark - file watcher

- (void)setWatchFilePath:(NSString *)watchFilePath {
    _watchFilePath = watchFilePath;
    self.filePath = watchFilePath;

    [self.class watchForChangesToFilePath:watchFilePath withCallback:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // reload styles
            _filePath = nil;
            self.filePath = watchFilePath;

            // reapply styles
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                [self styleSubviewsOfView:window];
            }
        });
    }];
}

- (void)styleSubviewsOfView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        [self styleView:subview];
        [self styleSubviewsOfView:subview];
    }
}

+ (void)watchForChangesToFilePath:(NSString *)filePath withCallback:(dispatch_block_t)callback {
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    int fileDescriptor = open([filePath UTF8String], O_EVTONLY);

    NSAssert(fileDescriptor > 0, @"Error could subscribe to events for file at path: %@", filePath);

    __block dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fileDescriptor,
                                                              DISPATCH_VNODE_DELETE | DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND,
                                                              queue);
    dispatch_source_set_event_handler(source, ^{
        unsigned long flags = dispatch_source_get_data(source);
        if (flags) {
            dispatch_source_cancel(source);
            callback();
            [self watchForChangesToFilePath:filePath withCallback:callback];
        }
    });
    dispatch_source_set_cancel_handler(source, ^(void){
        close(fileDescriptor);
    });
    dispatch_resume(source);
}

@end
