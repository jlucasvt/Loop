//
//  Chart.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 2/19/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import SwiftCharts

public protocol TargetPointsCalculator {
    var glucosePoints: [ChartPoint] { get }
    var overridePoints: [ChartPoint] { get }
    var overrideDurationPoints: [ChartPoint] { get }

    func calculate(_ xAxisValues: [ChartAxisValue]?)
}

public final class StatusChartsManager {
    public init(colors: ChartColorPalette, settings: ChartSettings) {
        self.colors = colors
        self.chartSettings = settings

        axisLabelSettings = ChartLabelSettings(font: UIFont.preferredFont(forTextStyle: UIFontTextStyle.caption1), fontColor: colors.axisLabel)

        guideLinesLayerSettings = ChartGuideLinesLayerSettings(linesColor: colors.grid)
    }

    // MARK: - Configuration

    private let colors: ChartColorPalette

    private let chartSettings: ChartSettings

    /// The amount of horizontal space reserved for fixed margins
    public var fixedHorizontalMargin: CGFloat {
        return chartSettings.leading + chartSettings.trailing + (chartSettings.labelsWidthY ?? 0) + chartSettings.labelsToAxisSpacingY
    }

    private var integerFormatter: NumberFormatter {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .none
        numberFormatter.maximumFractionDigits = 0

        return numberFormatter
    }

    private var axisLabelSettings: ChartLabelSettings

    private var guideLinesLayerSettings: ChartGuideLinesLayerSettings

    public var panGestureRecognizer: UIPanGestureRecognizer?

    public func didReceiveMemoryWarning() {
        xAxisValues = nil
        glucosePoints = []
        predictedGlucosePoints = []
        alternatePredictedGlucosePoints = nil
        targetGlucosePoints = []
        targetOverridePoints = []
        targetOverrideDurationPoints = []
        iobPoints = []
        cobPoints = []
        basalDosePoints = []
        bolusDosePoints = []
        allDosePoints = []

        glucoseChartCache = nil
        iobChartCache = nil
        cobChartCache = nil
        doseChartCache = nil
    }

    // MARK: - Data

    /// The earliest date on the X-axis
    public var startDate = Date() {
        didSet {
            if startDate != oldValue {
                xAxisValues = nil

                updateEndDate(startDate.addingTimeInterval(TimeInterval(hours: 4)))
            }
        }
    }

    /// The latest date on the X-axis
    private var endDate = Date() {
        didSet {
            if endDate != oldValue {
                xAxisValues = nil
            }
        }
    }

    /// Updates the endDate using a new candidate date
    /// 
    /// Dates are rounded up to the next hour.
    ///
    /// - Parameter date: The new candidate date
    private func updateEndDate(_ date: Date) {
        if date > endDate {
            var components = DateComponents()
            components.minute = 0
            endDate = Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .strict, direction: .forward) ?? date
        }
    }

    public var glucoseUnit: HKUnit = HKUnit.milligramsPerDeciliterUnit() {
        didSet {
            if glucoseUnit != oldValue {
                // Regenerate the glucose display points
                let oldRange = glucoseDisplayRange
                glucoseDisplayRange = oldRange
            }
        }
    }

    public var glucoseDisplayRange: (min: HKQuantity, max: HKQuantity)? {
        didSet {
            if let range = glucoseDisplayRange {
                glucoseDisplayRangePoints = [
                    ChartPoint(x: ChartAxisValue(scalar: 0), y: ChartAxisValueDouble(range.min.doubleValue(for: glucoseUnit))),
                    ChartPoint(x: ChartAxisValue(scalar: 0), y: ChartAxisValueDouble(range.max.doubleValue(for: glucoseUnit)))
                ]
            } else {
                glucoseDisplayRangePoints = []
            }
        }
    }

    // MARK: - State

    public var glucosePoints: [ChartPoint] = [] {
        didSet {
            glucoseChart = nil

            if let lastDate = glucosePoints.last?.x as? ChartAxisValueDate {
                updateEndDate(lastDate.date)
            }
        }
    }

    var glucoseDisplayRangePoints: [ChartPoint] = [] {
        didSet {
            glucoseChart = nil
        }
    }

    /// The chart points for predicted glucose
    public var predictedGlucosePoints: [ChartPoint] = [] {
        didSet {
            glucoseChart = nil

            if let lastDate = predictedGlucosePoints.last?.x as? ChartAxisValueDate {
                updateEndDate(lastDate.date)
            }
        }
    }

    /// The chart points for alternate predicted glucose
    public var alternatePredictedGlucosePoints: [ChartPoint]?

    public var targetPointsCalculator: TargetPointsCalculator? {
        didSet {
            targetGlucosePoints = []
        }
    }

    private var targetGlucosePoints: [ChartPoint] = [] {
        didSet {
            glucoseChart = nil
        }
    }

    private var targetOverridePoints: [ChartPoint] = [] {
        didSet {
            glucoseChart = nil
        }
    }

    private var targetOverrideDurationPoints: [ChartPoint] = [] {
        didSet {
            glucoseChart = nil
        }
    }

    /// The chart points for IOB
    public var iobPoints: [ChartPoint] = [] {
        didSet {
            iobChart = nil

            if let lastDate = iobPoints.last?.x as? ChartAxisValueDate {
                updateEndDate(lastDate.date)
            }
        }
    }

    /// The minimum range to display for insulin values.
    private let iobDisplayRangePoints: [ChartPoint] = [0, 1].map {
        return ChartPoint(
            x: ChartAxisValue(scalar: 0),
            y: ChartAxisValueInt($0)
        )
    }

    /// The chart points for COB
    public var cobPoints: [ChartPoint] = [] {
        didSet {
            cobChart = nil

            if let lastDate = cobPoints.last?.x as? ChartAxisValueDate {
                updateEndDate(lastDate.date)
            }
        }
    }

    /// The minimum range to display for COB values.
    private var cobDisplayRangePoints: [ChartPoint] = [0, 10].map {
        return ChartPoint(
            x: ChartAxisValue(scalar: 0),
            y: ChartAxisValueInt($0)
        )
    }

    public var basalDosePoints: [ChartPoint] = []
    public var bolusDosePoints: [ChartPoint] = []

    /// Dose points selectable when highlighting
    public var allDosePoints: [ChartPoint] = [] {
        didSet {
            doseChart = nil

            if let lastDate = allDosePoints.last?.x as? ChartAxisValueDate {
                updateEndDate(lastDate.date)
            }
        }
    }

    private var xAxisValues: [ChartAxisValue]? {
        didSet {
            if let xAxisValues = xAxisValues, xAxisValues.count > 1 {
                xAxisModel = ChartAxisModel(axisValues: xAxisValues, lineColor: colors.axisLine)
            } else {
                xAxisModel = nil
            }

            glucoseChart = nil
            iobChart = nil
            doseChart = nil
            cobChart = nil

            targetGlucosePoints = []
        }
    }

    private var xAxisModel: ChartAxisModel?

    private var glucoseChart: Chart?

    private var iobChart: Chart?

    private var cobChart: Chart?

    private var doseChart: Chart?

    private var glucoseChartCache: ChartPointsTouchHighlightLayerViewCache?

    private var iobChartCache: ChartPointsTouchHighlightLayerViewCache?

    private var cobChartCache: ChartPointsTouchHighlightLayerViewCache?

    private var doseChartCache: ChartPointsTouchHighlightLayerViewCache?

    // MARK: - Generators

    public func glucoseChartWithFrame(_ frame: CGRect) -> Chart? {
        if let chart = glucoseChart, chart.frame != frame {
            self.glucoseChart = nil
        }

        if glucoseChart == nil {
            glucoseChart = generateGlucoseChartWithFrame(frame)
        }

        return glucoseChart
    }

    private func generateGlucoseChartWithFrame(_ frame: CGRect) -> Chart? {
        guard let xAxisModel = xAxisModel else {
            return nil
        }

        let points = glucosePoints + predictedGlucosePoints + targetGlucosePoints + targetOverridePoints + glucoseDisplayRangePoints

        guard points.count > 1 else {
            return nil
        }

        let yAxisValues = ChartAxisValuesGenerator.generateYAxisValuesWithChartPoints(points,
            minSegmentCount: 2,
            maxSegmentCount: 4,
            multiple: glucoseUnit.glucoseUnitYAxisSegmentSize,
            axisValueGenerator: {
                ChartAxisValueDouble($0, labelSettings: self.axisLabelSettings)
            },
            addPaddingSegmentIfEdge: false
        )

        let yAxisModel = ChartAxisModel(axisValues: yAxisValues, lineColor: colors.axisLine)

        let coordsSpace = ChartCoordsSpaceLeftBottomSingleAxis(chartSettings: chartSettings, chartFrame: frame, xModel: xAxisModel, yModel: yAxisModel)

        let (xAxis, yAxis, innerFrame) = (coordsSpace.xAxis, coordsSpace.yAxis, coordsSpace.chartInnerFrame)

        // The glucose targets
        var targetLayer: ChartPointsAreaLayer? = nil

        if targetGlucosePoints.count > 1 {
            let alpha: CGFloat = targetOverridePoints.count > 1 ? 0.15 : 0.3

            targetLayer = ChartPointsAreaLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: targetGlucosePoints, areaColor: colors.glucoseTint.withAlphaComponent(alpha), animDuration: 0, animDelay: 0, addContainerPoints: false)
        }

        var targetOverrideLayer: ChartPointsAreaLayer? = nil

        if targetOverridePoints.count > 1 {
            targetOverrideLayer = ChartPointsAreaLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: targetOverridePoints, areaColor: colors.glucoseTint.withAlphaComponent(0.3), animDuration: 0, animDelay: 0, addContainerPoints: false)
        }

        var targetOverrideDurationLayer: ChartPointsAreaLayer? = nil

        if targetOverrideDurationPoints.count > 1 {
            targetOverrideDurationLayer = ChartPointsAreaLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: targetOverrideDurationPoints, areaColor: colors.glucoseTint.withAlphaComponent(0.3), animDuration: 0, animDelay: 0, addContainerPoints: false)
        }

        let gridLayer = ChartGuideLinesLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, axis: .xAndY, settings: guideLinesLayerSettings, onlyVisibleX: true, onlyVisibleY: false)

        let circles = ChartPointsScatterCirclesLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: glucosePoints, displayDelay: 0, itemSize: CGSize(width: 4, height: 4), itemFillColor: colors.glucoseTint)

        var alternatePrediction: ChartLayer?

        if let altPoints = alternatePredictedGlucosePoints, altPoints.count > 1 {
            // TODO: Bug in ChartPointsLineLayer requires a non-zero animation to draw the dash pattern
            let lineModel = ChartLineModel(chartPoints: altPoints, lineColor: colors.glucoseTint, lineWidth: 2, animDuration: 0.0001, animDelay: 0, dashPattern: [6, 5])

            alternatePrediction = ChartPointsLineLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, lineModels: [lineModel])
        }

        var prediction: ChartLayer?

        if predictedGlucosePoints.count > 1 {
            let lineColor = (alternatePrediction == nil) ? colors.glucoseTint : UIColor.secondaryLabelColor

            // TODO: Bug in ChartPointsLineLayer requires a non-zero animation to draw the dash pattern
            let lineModel = ChartLineModel(
                chartPoints: predictedGlucosePoints,
                lineColor: lineColor,
                lineWidth: 1,
                animDuration: 0.0001,
                animDelay: 0,
                dashPattern: [6, 5]
            )

            prediction = ChartPointsLineLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, lineModels: [lineModel])
        }

        if panGestureRecognizer != nil {
            glucoseChartCache = ChartPointsTouchHighlightLayerViewCache(
                xAxis: xAxis,
                yAxis: yAxis,
                innerFrame: innerFrame,
                chartPoints: glucosePoints + (alternatePredictedGlucosePoints ?? predictedGlucosePoints),
                tintColor: colors.glucoseTint,
                labelCenterY: chartSettings.top,
                gestureRecognizer: panGestureRecognizer
            )
        }

        let layers: [ChartLayer?] = [
            gridLayer,
            targetLayer,
            targetOverrideLayer,
            targetOverrideDurationLayer,
            xAxis,
            yAxis,
            glucoseChartCache?.highlightLayer,
            prediction,
            alternatePrediction,
            circles
        ]

        return Chart(frame: frame, layers: layers.flatMap { $0 })
    }

    public func iobChartWithFrame(_ frame: CGRect) -> Chart? {
        if let chart = iobChart, chart.frame != frame {
            self.iobChart = nil
        }

        if iobChart == nil {
            iobChart = generateIOBChartWithFrame(frame)
        }

        return iobChart
    }

    private func generateIOBChartWithFrame(_ frame: CGRect) -> Chart? {
        guard let xAxisModel = xAxisModel else {
            return nil
        }

        var containerPoints = iobPoints

        // Create a container line at 0
        if let first = iobPoints.first {
            containerPoints.insert(ChartPoint(x: first.x, y: ChartAxisValueInt(0)), at: 0)
        }

        if let last = iobPoints.last {
            containerPoints.append(ChartPoint(x: last.x, y: ChartAxisValueInt(0)))
        }

        let yAxisValues = ChartAxisValuesGenerator.generateYAxisValuesWithChartPoints(iobPoints + iobDisplayRangePoints, minSegmentCount: 2, maxSegmentCount: 3, multiple: 0.5, axisValueGenerator: { ChartAxisValueDouble($0, labelSettings: self.axisLabelSettings) }, addPaddingSegmentIfEdge: false)

        let yAxisModel = ChartAxisModel(axisValues: yAxisValues, lineColor: colors.axisLine)

        let coordsSpace = ChartCoordsSpaceLeftBottomSingleAxis(chartSettings: chartSettings, chartFrame: frame, xModel: xAxisModel, yModel: yAxisModel)

        let (xAxis, yAxis, innerFrame) = (coordsSpace.xAxis, coordsSpace.yAxis, coordsSpace.chartInnerFrame)

        // The IOB area
        let lineModel = ChartLineModel(chartPoints: iobPoints, lineColor: UIColor.IOBTintColor, lineWidth: 2, animDuration: 0, animDelay: 0)
        let iobLine = ChartPointsLineLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, lineModels: [lineModel])

        let iobArea: ChartPointsAreaLayer<ChartPoint>?

        if containerPoints.count > 1 {
            iobArea = ChartPointsAreaLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: containerPoints, areaColor: UIColor.IOBTintColor.withAlphaComponent(0.5), animDuration: 0, animDelay: 0, addContainerPoints: false)
        } else {
            iobArea = nil
        }

        // Grid lines
        let gridLayer = ChartGuideLinesLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, axis: .xAndY, settings: guideLinesLayerSettings, onlyVisibleX: true, onlyVisibleY: false)

        // 0-line
        let dummyZeroChartPoint = ChartPoint(x: ChartAxisValueDouble(0), y: ChartAxisValueDouble(0))
        let zeroGuidelineLayer = ChartPointsViewsLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: [dummyZeroChartPoint], viewGenerator: {(chartPointModel, layer, chart) -> UIView? in
            let width: CGFloat = 0.5
            let viewFrame = CGRect(x: innerFrame.origin.x, y: chartPointModel.screenLoc.y - width / 2, width: innerFrame.size.width, height: width)

            let v = UIView(frame: viewFrame)
            v.backgroundColor = UIColor.IOBTintColor
            return v
        })

        if panGestureRecognizer != nil {
            iobChartCache = ChartPointsTouchHighlightLayerViewCache(
                xAxis: xAxis,
                yAxis: yAxis,
                innerFrame: innerFrame,
                chartPoints: iobPoints,
                tintColor: UIColor.IOBTintColor,
                labelCenterY: chartSettings.top,
                gestureRecognizer: panGestureRecognizer
            )
        }

        let layers: [ChartLayer?] = [
            gridLayer,
            xAxis,
            yAxis,
            zeroGuidelineLayer,
            iobChartCache?.highlightLayer,
            iobArea,
            iobLine,
        ]

        return Chart(frame: frame, layers: layers.flatMap { $0 })
    }

    public func cobChartWithFrame(_ frame: CGRect) -> Chart? {
        if let chart = cobChart, chart.frame != frame {
            self.cobChart = nil
        }

        if cobChart == nil {
            cobChart = generateCOBChartWithFrame(frame)
        }

        return cobChart
    }

    private func generateCOBChartWithFrame(_ frame: CGRect) -> Chart? {
        guard let xAxisModel = xAxisModel else {
            return nil
        }

        var containerPoints = cobPoints

        // Create a container line at 0
        if let first = cobPoints.first {
            containerPoints.insert(ChartPoint(x: first.x, y: ChartAxisValueInt(0)), at: 0)
        }

        if let last = cobPoints.last {
            containerPoints.append(ChartPoint(x: last.x, y: ChartAxisValueInt(0)))
        }

        let yAxisValues = ChartAxisValuesGenerator.generateYAxisValuesWithChartPoints(cobPoints + cobDisplayRangePoints, minSegmentCount: 2, maxSegmentCount: 3, multiple: 10, axisValueGenerator: { ChartAxisValueDouble($0, labelSettings: self.axisLabelSettings) }, addPaddingSegmentIfEdge: false)

        let yAxisModel = ChartAxisModel(axisValues: yAxisValues, lineColor: colors.axisLine)

        let coordsSpace = ChartCoordsSpaceLeftBottomSingleAxis(chartSettings: chartSettings, chartFrame: frame, xModel: xAxisModel, yModel: yAxisModel)

        let (xAxis, yAxis, innerFrame) = (coordsSpace.xAxis, coordsSpace.yAxis, coordsSpace.chartInnerFrame)

        // The COB area
        let lineModel = ChartLineModel(chartPoints: cobPoints, lineColor: UIColor.COBTintColor, lineWidth: 2, animDuration: 0, animDelay: 0)
        let cobLine = ChartPointsLineLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, lineModels: [lineModel])

        let cobArea: ChartPointsAreaLayer<ChartPoint>?

        if containerPoints.count > 0 {
            cobArea = ChartPointsAreaLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: containerPoints, areaColor: UIColor.COBTintColor.withAlphaComponent(0.5), animDuration: 0, animDelay: 0, addContainerPoints: false)
        } else {
            cobArea = nil
        }

        // Grid lines
        let gridLayer = ChartGuideLinesLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, axis: .xAndY, settings: guideLinesLayerSettings, onlyVisibleX: true, onlyVisibleY: false)


        if panGestureRecognizer != nil {
            cobChartCache = ChartPointsTouchHighlightLayerViewCache(
                xAxis: xAxis,
                yAxis: yAxis,
                innerFrame: innerFrame,
                chartPoints: cobPoints,
                tintColor: UIColor.COBTintColor,
                labelCenterY: chartSettings.top,
                gestureRecognizer: panGestureRecognizer
            )
        }

        let layers: [ChartLayer?] = [
            gridLayer,
            xAxis,
            yAxis,
            cobChartCache?.highlightLayer,
            cobArea,
            cobLine
        ]

        return Chart(frame: frame, layers: layers.flatMap { $0 })
    }

    public func doseChartWithFrame(_ frame: CGRect) -> Chart? {
        if let chart = doseChart, chart.frame != frame {
            self.doseChart = nil
        }

        if doseChart == nil {
            doseChart = generateDoseChartWithFrame(frame)
        }

        return doseChart
    }

    private func generateDoseChartWithFrame(_ frame: CGRect) -> Chart? {
        guard let xAxisModel = xAxisModel else {
            return nil
        }

        let integerFormatter = self.integerFormatter

        let yAxisValues = ChartAxisValuesGenerator.generateYAxisValuesWithChartPoints(basalDosePoints + bolusDosePoints + iobDisplayRangePoints, minSegmentCount: 2, maxSegmentCount: 3, multiple: log10(2) / 2, axisValueGenerator: { ChartAxisValueDoubleLog(screenLocDouble: $0, formatter: integerFormatter, labelSettings: self.axisLabelSettings) }, addPaddingSegmentIfEdge: true)

        let yAxisModel = ChartAxisModel(axisValues: yAxisValues, lineColor: colors.axisLine)

        let coordsSpace = ChartCoordsSpaceLeftBottomSingleAxis(chartSettings: chartSettings, chartFrame: frame, xModel: xAxisModel, yModel: yAxisModel)

        let (xAxis, yAxis, innerFrame) = (coordsSpace.xAxis, coordsSpace.yAxis, coordsSpace.chartInnerFrame)

        // The dose area
        let lineModel = ChartLineModel(chartPoints: basalDosePoints, lineColor: colors.doseTint, lineWidth: 2, animDuration: 0, animDelay: 0)
        let doseLine = ChartPointsLineLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, lineModels: [lineModel])

        let doseArea: ChartPointsAreaLayer<ChartPoint>?

        if basalDosePoints.count > 1 {
            doseArea = ChartPointsAreaLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: basalDosePoints, areaColor: colors.doseTint.withAlphaComponent(0.5), animDuration: 0, animDelay: 0, addContainerPoints: false)
        } else {
            doseArea = nil
        }

        let bolusLayer: ChartPointsScatterDownTrianglesLayer<ChartPoint>?

        if bolusDosePoints.count > 0 {
            bolusLayer = ChartPointsScatterDownTrianglesLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: bolusDosePoints, displayDelay: 0, itemSize: CGSize(width: 12, height: 12), itemFillColor: colors.doseTint)
        } else {
            bolusLayer = nil
        }

        // Grid lines
        let gridLayer = ChartGuideLinesLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, axis: .xAndY, settings: guideLinesLayerSettings, onlyVisibleX: true, onlyVisibleY: false)

        // 0-line
        let dummyZeroChartPoint = ChartPoint(x: ChartAxisValueDouble(0), y: ChartAxisValueDouble(0))
        let zeroGuidelineLayer = ChartPointsViewsLayer(xAxis: xAxis, yAxis: yAxis, innerFrame: innerFrame, chartPoints: [dummyZeroChartPoint], viewGenerator: {(chartPointModel, layer, chart) -> UIView? in
            let width: CGFloat = 1
            let viewFrame = CGRect(x: innerFrame.origin.x, y: chartPointModel.screenLoc.y - width / 2, width: innerFrame.size.width, height: width)

            let v = UIView(frame: viewFrame)
            v.backgroundColor = self.colors.doseTint
            return v
        })

        if panGestureRecognizer != nil {
            doseChartCache = ChartPointsTouchHighlightLayerViewCache(
                xAxis: xAxis,
                yAxis: yAxis,
                innerFrame: innerFrame,
                chartPoints: allDosePoints,
                tintColor: colors.doseTint,
                labelCenterY: chartSettings.top,
                gestureRecognizer: panGestureRecognizer
            )
        }

        let layers: [ChartLayer?] = [
            gridLayer,
            xAxis,
            yAxis,
            zeroGuidelineLayer,
            doseChartCache?.highlightLayer,
            doseArea,
            doseLine,
            bolusLayer
        ]
        
        return Chart(frame: frame, layers: layers.flatMap { $0 })
    }

    private func generateXAxisValues() {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h a"

        let points = [
            ChartPoint(
                x: ChartAxisValueDate(date: startDate, formatter: timeFormatter),
                y: ChartAxisValue(scalar: 0)
            ),
            ChartPoint(
                x: ChartAxisValueDate(date: endDate, formatter: timeFormatter),
                y: ChartAxisValue(scalar: 0)
            )
        ]

        let xAxisValues = ChartAxisValuesGenerator.generateXAxisValuesWithChartPoints(points,
            minSegmentCount: 4,
            maxSegmentCount: 10,
            multiple: TimeInterval(hours: 1),
            axisValueGenerator: {
                ChartAxisValueDate(
                    date: ChartAxisValueDate.dateFromScalar($0),
                    formatter: timeFormatter,
                    labelSettings: self.axisLabelSettings
                )
            },
            addPaddingSegmentIfEdge: false
        )
        xAxisValues.first?.hidden = true
        xAxisValues.last?.hidden = true

        self.xAxisValues = xAxisValues
    }

    /// Runs any necessary steps before rendering charts
    public func prerender() {
        if xAxisValues == nil {
            generateXAxisValues()
        }

        if let calculator = targetPointsCalculator,
           targetGlucosePoints.count == 0 {
            calculator.calculate(xAxisValues)
            targetGlucosePoints = calculator.glucosePoints
            targetOverridePoints = calculator.overridePoints
            targetOverrideDurationPoints = calculator.overrideDurationPoints
        }
    }
}

private extension HKUnit {
    var glucoseUnitYAxisSegmentSize: Double {
        if self == HKUnit.milligramsPerDeciliterUnit() {
            return 25
        } else {
            return 1
        }
    }
}
