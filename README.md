# MedMaskMac

MedMaskMac is an early-stage, local-first macOS app for redacting sensitive information from Chinese medical documents before users share them with AI tools or other people.

The project focuses on privacy-sensitive fields commonly found in Chinese medical reports, including names, phone numbers, ID numbers, medical record numbers, inpatient numbers, addresses, dates, and similar information.

MedMaskMac is designed to reduce manual redaction work and help users review sensitive regions locally before exporting or sharing documents.

## Current Status

MedMaskMac is currently in early alpha. It is not yet a production-ready or fully automated privacy guarantee. OCR and automatic redaction can make mistakes, so users should manually review all redactions before sharing exported files.

## Key Features

- Import PDF, PNG, JPG, and JPEG files
- OCR-based sensitive information detection
- Standard and strict redaction modes
- Review and edit detected redaction candidates
- Preview original and redacted documents
- Export redacted documents
- Private local regression workflow for OCR testing

## Privacy

MedMaskMac is designed as a local-first tool. Documents are intended to be processed locally on the user's Mac by default.

Do not submit real personal, medical, financial, or identity documents in GitHub issues, pull requests, screenshots, or test fixtures. Use only synthetic or fully redacted samples.

---

## 中文说明

## 项目简介

MedMaskMac 是一个本地优先的 macOS 工具，用于在医疗 PDF 或图片文档对外分享前，辅助用户识别并遮盖可能包含敏感信息的区域。

项目目标是减少手动打码工作量，并降低敏感信息被意外暴露的风险。它不是云服务，也不是医疗分析平台。

## 解决什么问题

医疗报告、检查单、检验单等文档在发送给外部工具或人员前，通常需要去标识化处理。MedMaskMac 面向这个场景，提供一个本地工作流：

- 导入医疗 PDF 或图片。
- 使用本地 OCR 提示可能敏感的字段。
- 用户逐项复核候选结果。
- 用户可以选择遮盖、忽略、定位或撤销。
- 导出一份经过遮盖处理的副本。

用户仍然需要在导出或分享前手动检查最终结果。

## 核心功能

- 三种遮盖预设：Standard redaction、Strict redaction、Custom redaction。
- 本地 OCR 候选识别，不依赖云端 OCR。
- 敏感字段候选类型包括：
  - 姓名
  - 电话
  - 身份证号或其他 ID number
  - 门诊号、住院号、病历号、样本号等医疗编号
  - 生日、日期
  - 医院、科室
  - 电子邮件
  - Strict 模式下的工作人员、测试者签名字段
- 候选项操作：
  - redact：添加遮盖
  - ignore：忽略候选
  - locate：定位候选所在页面区域
  - undo：撤销候选处理

## 隐私设计

- Local-first：核心处理设计为在本机完成。
- 不使用云端 OCR。
- 不需要登录账号。
- 不加入分析统计。
- 不进行网络上传。
- 私有测试样本位于 `PrivateFixtures/`，该目录被 Git 忽略，不能提交到仓库。
- 用户必须在导出或分享前人工复核遮盖结果。

## 当前状态

项目处于早期开发和内部测试阶段。

当前重点是 OCR 候选识别与复核工作流。Standard 和 Strict 预设的 OCR 行为已有私有本地回归覆盖。导出、不可逆烧录遮盖，以及更完整的用户体验仍需要继续验证。

## 开发与验证

常用本地验证命令：

```bash
swift Scripts/run_private_ocr_regression.swift
```

```bash
xcodebuild -project MedMaskMac.xcodeproj -scheme MedMaskMac -configuration Debug build
```

```bash
grep -R "\[MedMaskOCR\]" -n MedMaskMac
```

```bash
git status --short
```

`Scripts/run_private_ocr_regression.swift` 依赖本地私有 fixture。不要把私有 fixture 文件加入 Git。

## 仓库安全约定

- `.build/` 已忽略。
- `PrivateFixtures/` 已忽略。
- 不提交医疗样本、包含隐私数据的截图、PDF、图片或私有 OCR 输出。
- 如需提交测试数据，应使用合成数据或已充分脱敏的数据。
- 文档、Issue、提交信息中不要包含真实患者、测试者、电话号码、证件号、生日、医院名称或原始 OCR 文本。

## 后续计划

- 继续提高 OCR 候选识别的稳健性。
- 继续验证 Standard、Strict、Custom 预设下的字段覆盖范围。
- 完善人工复核和候选处理体验。
- 验证导出副本中的不可逆遮盖效果。
- 保持本地优先和最小化数据暴露的产品边界。

## 免责声明

- 本工具仅用于辅助文档遮盖和去标识化处理。
- 用户在分享或导出前必须手动复核遮盖结果。
- 本工具不是医疗诊断工具。
- 本工具不提供法律、合规或认证建议。
- OCR 可能漏识别、误分类或产生不完整候选。
