#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <bsm/libbsm.h>
#import <objc/runtime.h>
#include "SceneWallpaperBindings.h"

// Private macOS wallpaper hosting ABI, resolved/checked before use.
// Protocol reference: kageroumado/phosphene, revision 8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6.
@interface CAContext : NSObject
@property(nonatomic, readonly) unsigned int contextId;
@property(nonatomic, retain) CALayer *layer;
- (void)invalidate;
@end

@interface NSXPCConnection (WallpaperCallerIdentity)
@property(nonatomic, readonly) audit_token_t auditToken;
@end

@protocol WallpaperExtensionXPCProtocol <NSObject>
- (void)acquireWithId:(id)identifier request:(id)request reply:(void (^)(id, NSError *))reply;
- (void)updateWithId:(id)identifier request:(id)request reply:(void (^)(NSError *))reply;
- (void)invalidateWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)snapshotWithId:(id)identifier reply:(void (^)(id, NSError *))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id)types reply:(void (^)(id, NSError *))reply;
- (void)isChoiceDownloadedWith:(id)choiceID reply:(void (^)(BOOL, NSError *))reply;
- (void)selectedChoicesDidChangeFor:(id)identifier reply:(void (^)(NSError *))reply;
@end
