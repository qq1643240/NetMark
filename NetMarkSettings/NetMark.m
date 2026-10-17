//
//  NetMark.m
//  NetMark 设置面板
//
//  原生 insetGrouped 列表：勾选式选项 + 行内自定义输入 + 居中文字按钮。
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
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:NMPreferencesPath];
    if (stored.count == 0) {
        // 从旧版（Data Logo Switcher）迁移：先找正常路径，再找 rootless 误写路径
        NSArray<NSString *> *legacyPaths = @[ NMLegacyPreferencesPath, NMLegacyRootlessPath ];
        for (NSString *legacyPath in legacyPaths) {
            if ([legacyPath isEqualToString:NMPreferencesPath]) {
                continue;
            }
            stored = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
            if (stored.count > 0) {
                break;
            }
        }
    }
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void NMStorePreferences(NSDictionary *preferences) {
    NSString *directory = [NMPreferencesPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [preferences writeToFile:NMPreferencesPath atomically:YES];
}

// 旧版数据迁移：移除 3G 相关键，并把已删除的跨制式选项回落到默认值。
static void NMMigratePreferences(NSMutableDictionary *preferences) {
    if ([preferences[NMKeySchemaVersion] integerValue] >= 2) {
        return;
    }

    // 旧 4G 表的 5...9（5GE / 5G / 5G+ / 5G UWB / 5G UC）已删除
    NSInteger mode4G = [preferences[NMKey4GMode] integerValue];
    if (mode4G > NM4GOption4GPlus && mode4G != NM4GOptionCustom) {
        preferences[NMKey4GMode] = @(NM4GOptionDefault);
    }

    // 旧 5G 表：3 = 5G UWB，4 = 5G UC；新表顺延为 4 / 5
    NSInteger mode5G = [preferences[NMKey5GMode] integerValue];
    if (mode5G == 3) {
        preferences[NMKey5GMode] = @(NM5GOption5GUWB);
    } else if (mode5G == 4) {
        preferences[NMKey5GMode] = @(NM5GOption5GUC);
    } else if (mode5G > NM5GOption5GUC && mode5G != NM5GOptionCustom) {
        preferences[NMKey5GMode] = @(NM5GOptionDefault);
    }

    [preferences removeObjectForKey:@"3G"];
    [preferences removeObjectForKey:@"custom3GString"];

    preferences[NMKeySchemaVersion] = @2;
    NMStorePreferences(preferences);
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

static void NMRespringDevice(void) {
    NSString *sbreloadPath = ROOT_PATH_NS(@"/usr/bin/sbreload");
    if ([[NSFileManager defaultManager] fileExistsAtPath:sbreloadPath]) {
        NMSpawnProcess(sbreloadPath, @[]);
        return;
    }

    NSArray<NSString *> *killallPaths = @[ ROOT_PATH_NS(@"/usr/bin/killall"), @"/usr/bin/killall" ];
    for (NSString *killallPath in killallPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:killallPath]) {
            NMSpawnProcess(killallPath, @[ @"-9", @"SpringBoard" ]);
            NMSpawnProcess(killallPath, @[ @"-9", @"backboardd" ]);
            return;
        }
    }
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
@end

@implementation NMRootViewController

#pragma mark 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"NetMark";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.preferences = NMLoadPreferences();
    NMMigratePreferences(self.preferences);

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
        return @"4G / LTE";
    }
    if (section == NMSection5G) {
        return @"5G";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NMSection4G) {
        NSString *label = NM4GLabelForValue(self.mode4G, self.custom4G);
        return label ? [NSString stringWithFormat:@"4G / LTE 网络下显示「%@」。", label]
                     : @"4G / LTE 网络下跟随系统显示。";
    }
    if (section == NMSection5G) {
        NSString *label = NM5GLabelForValue(self.mode5G, self.custom5G);
        return label ? [NSString stringWithFormat:@"5G 网络下显示「%@」。", label]
                     : @"5G 网络下跟随系统显示。";
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
    self.preferences[NMKeySchemaVersion] = @2;
    NMStorePreferences(self.preferences);
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

    NSInteger section = (field == self.custom4GField) ? NMSection4G : NMSection5G;
    // 等输入框事件走完再刷新该分组，用于更新底部说明中的当前标识
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)section]
                     withRowAnimation:UITableViewRowAnimationNone];
    });
}

- (void)respring {
    [self.view endEditing:YES];
    [self persistPreferences];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NMRespringDevice();
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
