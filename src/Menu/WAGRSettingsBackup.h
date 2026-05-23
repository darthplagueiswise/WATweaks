#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRSettingsBackup : NSObject
+ (void)presentExport;
+ (void)presentImport;
+ (void)presentReset;
@end

#ifdef __cplusplus
extern "C" {
#endif
NSString *WAGRSettingsBackupDiagnosticText(void);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
