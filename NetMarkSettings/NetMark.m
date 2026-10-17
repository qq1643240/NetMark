//
//  NetMark.m
//  NetMark 设置面板
//
//  原生 insetGrouped 列表：顶部状态总览 + 两个制式分组 + 底部操作行。
//  不使用任何自绘视图，外观完全跟随系统设置页。
//

#import "NetMark.h"
#import <spawn.h>

static NSString *const kNMOptionCellIdentifier = @"NMOptionCell";
static NSString *const kNMActionCellIdentifier = @"NMActionCell";

typedef NS_ENUM(NSInteger, NMSection) {
    NMSection4G = 0,
    NMSection5G,
    NMSectionAction,
    NMSectionCount
};

#pragma mark - 偏好读写

static NSMutableDictionary *NMLoadPreferences(void) {
    // 两个写入位置都看，取 mtime 最新的那份
    NSDictionary *newest = nil;
    NSTimeInterval newestStamp = -1;
    for (NSString *path in NMPreferencePaths()) {
        NSDictionary *attributes = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:path error:NULL];
        NSDate *modifiedDate = attributes[NSFileModificationDate];
        NSTimeInterval pathStamp = modifiedDate ? [modifiedDate timeIntervalSinceReferenceDate] : 0;
        if (pathStamp <= newestStamp) {
            continue;
        }
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:path];
        if (loaded.count > 0) {
            newest = loaded;
            newestStamp = pathStamp;
        }
    }

    if (newest.count == 0) {
        // 从旧版（Data Logo Switcher）迁移：先找正常路径，再找 rootless 误写路径
        NSArray<NSString *> *legacyPaths = @[ NMLegacyPreferencesPath, NMLegacyRootlessPath ];
        for (NSString *legacyPath in legacyPaths) {
            if ([NMPreferencePaths() containsObject:legacyPath]) {
                continue;
            }
            newest = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
            if (newest.count > 0) {
                break;
            }
        }
    }
    return newest ? [newest mutableCopy] : [NSMutableDictionary dictionary];
}

// 两个位置都写：哪个进程能看到哪份就用哪份。返回是否至少成功写了一份。
static BOOL NMStorePreferences(NSDictionary *preferences) {
    BOOL wroteAny = NO;
    for (NSString *path in NMPreferencePaths()) {
        NSString *directory = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        if ([preferences writeToFile:path atomically:YES]) {
            wroteAny = YES;
        }
    }
    return wroteAny;
}

// 旧版数据迁移：清理已删除的键，并把已移除的选项回落到默认值。
// 返回写入是否成功（无迁移时视为成功）。
static BOOL NMMigratePreferences(NSMutableDictionary *preferences) {
    if ([preferences[NMKeySchemaVersion] integerValue] >= 3) {
        return YES;
    }

    // 4G 表只保留 0(默认) / 3(4Gᴀ) / 4(4G+) / 99(自定义)
    NSInteger mode4G = [preferences[NMKey4GMode] integerValue];
    if (mode4G != NM4GOptionDefault && mode4G != NM4GOption4GA &&
        mode4G != NM4GOption4GPlus && mode4G != NM4GOptionCustom) {
        preferences[NMKey4GMode] = @(NM4GOptionDefault);
    }

    // 5G 表只保留 0(默认) / 2(5G+) / 3(5Gᴀ) / 4(5G UWB) / 5(5G UC) / 99(自定义)
    NSInteger mode5G = [preferences[NMKey5GMode] integerValue];
    if (mode5G != NM5GOptionDefault && mode5G != NM5GOption5GPlus && mode5G != NM5GOption5GA &&
        mode5G != NM5GOption5GUWB && mode5G != NM5GOption5GUC && mode5G != NM5GOptionCustom) {
        preferences[NMKey5GMode] = @(NM5GOptionDefault);
    }

    [preferences removeObjectForKey:@"3G"];
    [preferences removeObjectForKey:@"custom3GString"];

    preferences[NMKeySchemaVersion] = @3;
    return NMStorePreferences(preferences);
}

#pragma mark - 注销

static void NMSpawnProcess(NSString *path, NSArray<NSString *> *arguments) {
    if (path.length == 0) {
        return;
    }
    const char *argv[16];
    NSUInteger index = 0;
    argv[index++] = path.UTF8String;
    for (NSString *argument in arguments) {
        if (index >= 15) {
            break;
        }
        argv[index++] = argument.UTF8String;
    }
    argv[index] = NULL;

    pid_t pid = 0;
    posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)argv, NULL);
}

// 从自身 bundle 位置反推越狱根目录：
//   rootless  <root>/Library/PreferenceBundles/NetMark.bundle  → /var/jb
//   roothide  <jbroot>/Library/PreferenceBundles/NetMark.bundle → .jbroot-XXXX
//   rootful   /Library/PreferenceBundles/NetMark.bundle         → /
static NSString *NMJailbreakRoot(void) {
    NSString *bundlePath = [NSBundle bundleForClass:[NMRootViewController class]].bundlePath;
    if (bundlePath.length == 0) {
        return nil;
    }
    NSString *root = [[[bundlePath stringByDeletingLastPathComponent]
                       stringByDeletingLastPathComponent]
                      stringByDeletingLastPathComponent];
    return root.length > 0 ? root : nil;
}

static NSArray<NSString *> *NMCandidateRoots(void) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *derived = NMJailbreakRoot();
    if (derived.length > 0) {
        [roots addObject:derived];
    }
    for (NSString *fallback in @[ @"/var/jb", @"/" ]) {
        if (![roots containsObject:fallback]) {
            [roots addObject:fallback];
        }
    }
    return roots;
}

// 返回 YES 表示已经发起注销；NO 表示找不到可用的 sbreload / killall。
static BOOL NMRespringDevice(void) {
    NSArray<NSString *> *roots = NMCandidateRoots();

    for (NSString *root in roots) {
        NSString *sbreloadPath = [root stringByAppendingPathComponent:@"usr/bin/sbreload"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:sbreloadPath]) {
            NMSpawnProcess(sbreloadPath, @[]);
            return YES;
        }
    }

    for (NSString *root in roots) {
        NSString *killallPath = [root stringByAppendingPathComponent:@"usr/bin/killall"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:killallPath]) {
            NMSpawnProcess(killallPath, @[ @"-9", @"SpringBoard" ]);
            NMSpawnProcess(killallPath, @[ @"-9", @"backboardd" ]);
            return YES;
        }
    }

    return NO;
}

#pragma mark - 设置页

@interface NMRootViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *preferences;
@property (nonatomic, strong) UITextField *custom4GField;
@property (nonatomic, strong) UITextField *custom5GField;
@property (nonatomic, assign) NSInteger mode4G;
@property (nonatomic, assign) NSInteger mode5G;
@property (nonatomic, copy) NSString *custom4G;
@property (nonatomic, copy) NSString *custom5G;
@property (nonatomic, assign) BOOL writeSucceeded;
@end

@implementation NMRootViewController

#pragma mark 生命周期

- (void)loadView {
    // PSViewController 的视图由 specifier 驱动，这里换成自绘容器，
    // 保证 viewDidLoad 里拿到的是我们自己的 view。
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"NetMark";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.preferences = NMLoadPreferences();
    self.writeSucceeded = NMMigratePreferences(self.preferences);

    self.mode4G = [self.preferences[NMKey4GMode] integerValue];
    self.mode5G = [self.preferences[NMKey5GMode] integerValue];
    self.custom4G = self.preferences[NMKey4GCustom] ?: @"";
    self.custom5G = self.preferences[NMKey5GCustom] ?: @"";

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIKeyboardWillChangeFrameNotification
                                                  object:nil];
    [self persistPreferences];
}

#pragma mark 选项表

- (NSArray<NSNumber *> *)optionValuesForSection:(NSInteger)section {
    return (section == NMSection4G) ? NM4GOptionValues() : NM5GOptionValues();
}

- (NSArray<NSString *> *)optionTitlesForSection:(NSInteger)section {
    return (section == NMSection4G) ? NM4GOptionTitles() : NM5GOptionTitles();
}

- (NSInteger)selectedValueForSection:(NSInteger)section {
    return (section == NMSection4G) ? self.mode4G : self.mode5G;
}

- (NSInteger)customValueForSection:(NSInteger)section {
    return (section == NMSection4G) ? NM4GOptionCustom : NM5GOptionCustom;
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return NMSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == NMSectionAction) {
        return 1;
    }
    NSInteger count = (NSInteger)[self optionValuesForSection:section].count;
    if ([self selectedValueForSection:section] == [self customValueForSection:section]) {
        count += 1;   // 自定义文本输入行
    }
    return count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == NMSection4G) {
        return @"4G";
    }
    if (section == NMSection5G) {
        return @"5G";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NMSection4G) {
        NSString *label = NM4GLabelForValue(self.mode4G, self.custom4G);
        return label ? [NSString stringWithFormat:@"4G 网络下显示「%@」。", label]
                     : @"4G 网络下跟随系统显示。";
    }
    if (section == NMSection5G) {
        NSString *label = NM5GLabelForValue(self.mode5G, self.custom5G);
        return label ? [NSString stringWithFormat:@"5G 网络下显示「%@」。", label]
                     : @"5G 网络下跟随系统显示。";
    }
    if (!self.writeSucceeded) {
        return @"⚠️ 设置写入失败，请检查越狱环境或磁盘权限。";
    }
    return @"修改后需注销才能生效；「默认」表示完全跟随系统与运营商设置。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == NMSectionAction) {
        return [self actionCellForTableView:tableView];
    }

    NSArray<NSNumber *> *values = [self optionValuesForSection:indexPath.section];
    if (indexPath.row >= (NSInteger)values.count) {
        return [self customCellForSection:indexPath.section];
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kNMOptionCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kNMOptionCellIdentifier];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    }

    cell.textLabel.text = [self optionTitlesForSection:indexPath.section][(NSUInteger)indexPath.row];
    BOOL selected = (values[(NSUInteger)indexPath.row].integerValue ==
                     [self selectedValueForSection:indexPath.section]);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    return cell;
}

#pragma mark UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == NMSectionAction) {
        [self respring];
        return;
    }

    NSArray<NSNumber *> *values = [self optionValuesForSection:indexPath.section];
    if (indexPath.row >= (NSInteger)values.count) {
        return;   // 点中输入行本身不做处理
    }

    NSInteger value = values[(NSUInteger)indexPath.row].integerValue;
    BOOL is4G = (indexPath.section == NMSection4G);
    if (is4G) {
        self.mode4G = value;
    } else {
        self.mode5G = value;
    }
    [self persistPreferences];

    BOOL needsFocus = (value == [self customValueForSection:indexPath.section]);
    // 选择动画结束后再刷新分组，避免在选中回调里同步改动数据源
    dispatch_async(dispatch_get_main_queue(), ^{
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)indexPath.section]
                 withRowAnimation:UITableViewRowAnimationAutomatic];

        if (needsFocus) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UITextField *field = is4G ? self.custom4GField : self.custom5GField;
                [field becomeFirstResponder];
            });
        }
    });
}

#pragma mark 单元格

- (UITableViewCell *)actionCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kNMActionCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kNMActionCellIdentifier];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    }
    cell.textLabel.text = @"保存并注销";
    cell.textLabel.textColor = self.view.tintColor;
    return cell;
}

- (UITableViewCell *)customCellForSection:(NSInteger)section {
    BOOL is4G = (section == NMSection4G);

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.textColor = [UIColor labelColor];
    field.text = is4G ? self.custom4G : self.custom5G;
    field.placeholder = @"输入自定义标识";
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    [field addTarget:self
              action:@selector(customTextDidChange:)
    forControlEvents:UIControlEventEditingChanged];
    [field addTarget:self
              action:@selector(customTextDidEndEditing:)
    forControlEvents:UIControlEventEditingDidEnd];
    [cell.contentView addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
        [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        [field.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];

    if (is4G) {
        self.custom4GField = field;
    } else {
        self.custom5GField = field;
    }
    return cell;
}

#pragma mark 状态

- (void)persistPreferences {
    self.preferences[NMKey4GMode] = @(self.mode4G);
    self.preferences[NMKey5GMode] = @(self.mode5G);
    self.preferences[NMKey4GCustom] = self.custom4G ?: @"";
    self.preferences[NMKey5GCustom] = self.custom5G ?: @"";
    self.preferences[NMKeySchemaVersion] = @3;

    BOOL previous = self.writeSucceeded;
    self.writeSucceeded = NMStorePreferences(self.preferences);

    if (previous != self.writeSucceeded) {
        // 只在状态变化时刷新，避免每次点选都闪一下
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:NMSectionAction]
                         withRowAnimation:UITableViewRowAnimationNone];
        });
    }
}

- (void)customTextDidChange:(UITextField *)field {
    if (field == self.custom4GField) {
        self.custom4G = field.text ?: @"";
    } else if (field == self.custom5GField) {
        self.custom5G = field.text ?: @"";
    }
}

- (void)customTextDidEndEditing:(UITextField *)field {
    [self customTextDidChange:field];
    [self persistPreferences];

    // 等输入框事件走完再刷新分组说明
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger section = (field == self.custom4GField) ? NMSection4G : NMSection5G;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)section]
                     withRowAnimation:UITableViewRowAnimationNone];
    });
}

- (void)respring {
    [self.view endEditing:YES];
    [self persistPreferences];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!NMRespringDevice()) {
            // 找不到 sbreload / killall 时明确告知，避免"点了没反应"
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"无法自动注销"
                                                message:@"没找到 sbreload 或 killall，设置已保存，请手动注销设备。"
                                         preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
}

#pragma mark UITextFieldDelegate

- (BOOL)textField:(UITextField *)textField
shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string {
    // 输入法候选态不拦截，避免破坏中文输入
    if (textField.markedTextRange != nil) {
        return YES;
    }
    NSString *proposed = [textField.text stringByReplacingCharactersInRange:range withString:string];
    return proposed.length <= NMMaxCustomLength;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark 键盘

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect converted = [self.tableView convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.tableView.bounds) - CGRectGetMinY(converted));

    UIEdgeInsets inset = self.tableView.contentInset;
    inset.bottom = overlap > 0 ? overlap : 0.0;
    self.tableView.contentInset = inset;
    self.tableView.scrollIndicatorInsets = inset;
}

@end
