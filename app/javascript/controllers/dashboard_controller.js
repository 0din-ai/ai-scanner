import { Controller } from "@hotwired/stimulus"
import { colors, isDark } from "graphs/common"
import { disposeCharts, resizeCharts } from "utils"
import { tooltipConfig, baseChartConfig, getGaugeColor, hexToRgba, CHART_COLORS, CHART_COLOR_PALETTE, TEXT_COLORS, CHART_CONSTANTS, wrapText, handleChartError, BRAND_FONT } from "config/chartConfig"

export default class extends Controller {
    static targets = [
        "totalHits1",
        "percentage1",
        "periodLabel1",
        "sparklineChart1",
        "totalHits2",
        "percentage2",
        "periodLabel2",
        "sparklineChart2",
        "totalHits3",
        "sparklineChart3",
        "totalHits4",
        "percentage4",
        "periodLabel4",
        "sparklineChart4",
        "vulnerableTargetsChart",
        "detectorActivityRadarChart",
        "taxonomyDistributionChart",
        "probeDisclosureChart",
        "scanAndTargetCountsChart"
    ]

    async connect() {
        await import("/js/echarts.js");
        this.charts = {};

        // Store handler reference for cleanup in disconnect()
        this.resizeHandler = () => resizeCharts(this.charts);
        window.addEventListener('resize', this.resizeHandler);

        this.initCharts();
    }

    disconnect() {
        // Remove event listener before disposing charts to prevent memory leak
        if (this.resizeHandler) {
            window.removeEventListener('resize', this.resizeHandler);
            this.resizeHandler = null;
        }
        disposeCharts(this.charts);
    }

    changeGlobalPeriod(period) {
        if (!period) return;
        // Update all charts that support period changes
        this.loadTotalProbesData(period);
        this.changeTotalScansTimePeriod(period);
        this.changeAvgAsrTimePeriod(period);
        this.changeAvgScanTimePeriod(period);
        this.changeVulnerableTargetsPeriod(period);
    }

    initCharts() {
        const chartConfig = {
            ...baseChartConfig(colors),
            backgroundColor: 'transparent',
            tooltip: tooltipConfig
        };
        this.initTotalProbes(chartConfig);
        this.initTotalScans(chartConfig);
        this.initAvgAsrScores(chartConfig);
        this.initAvgScans(chartConfig);
        this.initVulnerableTargetsChart(chartConfig);
        this.initDetectorActivityRadarChart(chartConfig);
        this.initTaxonomyDistributionChart(chartConfig);
        this.initProbeDisclosureChart(chartConfig);
        this.initScanAndTargetCountsChart(chartConfig);
    }

    initChart(element, chartConfig) {
        const chart = echarts.init(element);
        chart.setOption(chartConfig);
        const chartKeyValue = this.getChartKeyFromElement(element);
        this.charts[chartKeyValue] = chart;
        return chart;
    }

    getLineColor(element, growthPositive) {
        if (element.dataset.dashboardTarget === CHART_CONSTANTS.ASR_SPARKLINE_TARGET) return CHART_COLORS.ORANGE; // Orange for ASR
        return growthPositive ? '#3AB37E' : CHART_COLORS.RED; // Green or Red
    }

    initTotalProbes(chartConfig) {
        this.loadTotalProbesData(30, chartConfig);
    }

    loadTotalProbesData(days, chartConfig = null) {
        if (!chartConfig) {
            chartConfig = {
                ...baseChartConfig(colors),
                backgroundColor: 'transparent',
                tooltip: tooltipConfig
            };
        }
        fetch(`/dashboard_stats/probes_data?days=${days}`)
            .then(response => response.json())
            .then(data => {
                this.totalHits1Target.innerText = data.total.toString();
                const percentageNew = data.percentage_new_last_30_days;

                if (percentageNew === 0) {
                    this.updatePercentageElement(this.percentage1Target, '0%', true, TEXT_COLORS.NEUTRAL);
                } else {
                    const isPositiveContext = percentageNew > 0;
                    const prefix = isPositiveContext ? '+' : '';
                    this.updatePercentageElement(this.percentage1Target, `${prefix}${percentageNew}%`, isPositiveContext);
                }

                this.upsertSparklineChart(chartConfig, this.sparklineChart1Target, data.counts, percentageNew >= 0);
            });
    }

    updatePercentageElement(element, text, isPositiveForColorContext, specialColorClass = null) {
        element.innerText = text;
        element.classList.remove(TEXT_COLORS.POSITIVE, TEXT_COLORS.NEGATIVE, TEXT_COLORS.NEUTRAL);
        if (specialColorClass) {
            element.classList.add(specialColorClass);
        } else {
            element.classList.add(this.getPercentageTextColorClass(isPositiveForColorContext));
        }
    }

    getSparklineAreaColor(growthPositive, isAsr = false) {
        let startColor, endColor;
        if (isAsr) {
            // Orange gradient for ASR
            startColor = hexToRgba(CHART_COLORS.ORANGE, 0.5);
            endColor = hexToRgba(CHART_COLORS.ORANGE, 0);
        } else if (growthPositive) {
            // Green gradient
            startColor = 'rgba(58, 179, 126, 0.6)';   // #3AB37E at 60% opacity
            endColor = 'rgba(58, 179, 126, 0)';       // #3AB37E at 0% opacity
        } else {
            // Red gradient
            startColor = hexToRgba(CHART_COLORS.RED, 0.6);
            endColor = hexToRgba(CHART_COLORS.RED, 0);
        }
        return {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
                { offset: 0, color: startColor },
                { offset: 1, color: endColor }
            ])
        }
    }

    getPercentageTextColorClass(growthPositive) {
        return growthPositive ? TEXT_COLORS.POSITIVE : TEXT_COLORS.NEGATIVE;
    }

    initTotalScans(chartConfig) {
        if (!this.hasTotalHits2Target) return;
        this.loadTotalScansData(30, chartConfig);
    }

    changeTotalScansTimePeriod(period) {
        if (!period || !this.hasTotalHits2Target) return;
        const chartConfig = {
            ...baseChartConfig(colors),
            backgroundColor: 'transparent',
            tooltip: tooltipConfig
        };
        this.loadTotalScansData(period, chartConfig);
    }

    loadTotalScansData(days, chartConfig) {
        fetch(`/dashboard_stats/total_scans_data?days=${days}`)
            .then(response => response.json())
            .then(data => {
                this.totalHits2Target.innerText = data.total.toString();
                const percentageValue = data.percentage_change;
                const isPositiveContext = percentageValue >= 0;
                this.updatePercentageElement(this.percentage2Target, `${isPositiveContext ? '+' : ''}${percentageValue}%`, isPositiveContext);
                this.upsertSparklineChart(chartConfig, this.sparklineChart2Target, data.counts, data.percentage_change >= 0);
            });
    }

    initAvgAsrScores(chartConfig, period = 30) {
        fetch('/dashboard_stats/avg_asr_score?days=' + period)
            .then(response => response.json())
            .then(data => {
                this.totalHits3Target.innerText = data.score + "%";
                this.upsertSparklineChart(
                    chartConfig,
                    this.sparklineChart3Target,
                    this.prepareRatesForLineChart(data.data.rates),
                    true
                );
            })
    }

    changeAvgAsrTimePeriod(period) {
        const chartConfig = {
            ...baseChartConfig(colors),
            backgroundColor: 'transparent',
            tooltip: tooltipConfig
        };
        this.initAvgAsrScores(chartConfig, period);
    }

    prepareRatesForLineChart(rates) {
        if (!rates || rates.length === 0) {
            return [0, 0];
        } else if (rates.length === 1) {
            return [rates[0], rates[0]];
        }
        return rates;
    }

    initAvgScans(chartConfig) {
        this.loadAvgScanTimeData(30, chartConfig);
    }

    changeAvgScanTimePeriod(period) {
        const selectedDays = period;
        this.loadAvgScanTimeData(selectedDays, {
            grid: {
                show: false,
                top: 0,
                right: 0,
                bottom: 0,
                left: 0
            }
        });
    }

    loadAvgScanTimeData(days, chartConfig) {
        const endpoint = `/dashboard_stats/avg_scan_time_data?days=${days || 7}`;
        fetch(endpoint)
            .then(response => response.json())
            .then(data => {
                const formattedTime = data.formatted_time || "0s";
                const smallTextClasses = ['text-xl', 'sm:text-2xl', 'md:text-2xl'];
                const largeTextClasses = ['text-2xl', 'sm:text-3xl', 'md:text-3xl'];
                this.totalHits4Target.textContent = formattedTime;
                if (formattedTime.includes(' ') && formattedTime.length > 6) {
                    this.totalHits4Target.classList.add(...smallTextClasses);
                    this.totalHits4Target.classList.remove(...largeTextClasses);
                } else {
                    this.totalHits4Target.classList.add(...largeTextClasses);
                    this.totalHits4Target.classList.remove(...smallTextClasses);
                }
                const percentageChange = data.percentage_change;
                if (percentageChange === null || percentageChange === undefined) {
                    this.updatePercentageElement(this.percentage4Target, "N/A", true, TEXT_COLORS.NEUTRAL);
                } else if (percentageChange === 0) {
                    this.updatePercentageElement(this.percentage4Target, "No change", true, TEXT_COLORS.NEUTRAL);
                } else {
                    const isImprovement = percentageChange <= 0;
                    const prefix = isImprovement ? "" : "+";
                    this.updatePercentageElement(this.percentage4Target, `${prefix}${percentageChange}%`, isImprovement);
                }
                const isPositiveForChartStyle = percentageChange === null ? true : percentageChange <= 0;
                this.upsertSparklineChart(chartConfig, this.sparklineChart4Target, data.trend_data, isPositiveForChartStyle);
            });
    }

    upsertSparklineChart(chartConfig, element, data, growthPositive) {
        const chartKeyValue = this.getChartKeyFromElement(element);
        if (this.charts[chartKeyValue]) {
            this.charts[chartKeyValue].dispose();
            delete this.charts[chartKeyValue];
        }
        const chart = echarts.init(element);
        const lineColor = this.getLineColor(element, growthPositive);
        chart.setOption({
            grid: { left: 0, right: 0, top: 4, bottom: 4 },
            xAxis: {
                type: 'category',
                data,
                axisLabel: { show: false },
                axisTick: { show: false },
                axisLine: { show: false },
                axisPointer: { show: false }
            },
            yAxis: {
                type: 'value',
                axisLabel: { show: false },
                axisTick: { show: false },
                axisLine: { show: false },
                axisPointer: { show: false },
                splitLine: { show: false }
            },
            series: [{
                type: 'line',
                data,
                smooth: true,
                symbol: 'none',
                showSymbol: false,
                symbolSize: 0,
                lineStyle: { width: CHART_CONSTANTS.LINE_WIDTH_DEFAULT, color: lineColor },
                areaStyle: this.getSparklineAreaColor(growthPositive, element.dataset.dashboardTarget === 'sparklineChart3'),
                markLine: {
                    silent: true,
                    symbol: 'none',
                    data: [{
                        yAxis: 'min',
                        lineStyle: {
                            color: 'rgba(156, 163, 175, 0.3)',
                            type: [3, 5],
                            width: 1
                        }
                    }],
                    label: { show: false }
                },
                emphasis: {
                    disabled: true,
                    focus: 'none',
                    itemStyle: {
                        borderWidth: 0
                    }
                },
                select: {
                    disabled: true
                }
            }],
            tooltip: {
                show: false
            },
            backgroundColor: 'transparent'
        });

        // Disable all mouse events
        chart.getZr().off('mousemove');
        chart.getZr().off('mouseout');
        chart.getZr().off('click');

        this.charts[chartKeyValue] = chart;
    }

    initVulnerableTargetsChart(chartConfig) {
        const chart = this.initChart(this.vulnerableTargetsChartTarget, chartConfig);
        this.loadVulnerableTargetsData(30, chart, chartConfig);
    }

    changeVulnerableTargetsPeriod(period) {
        const selectedDays = period;
        const targetElement = this.vulnerableTargetsChartTarget;
        const chartKeyValue = this.getChartKeyFromElement(targetElement);
        const vulnerableTargetsChartConfig = {
            ...baseChartConfig(colors),
            backgroundColor: 'transparent',
            legend: {
                textStyle: {
                    color: isDark ? '#FFFFFF' : colors.textColor,
                    fontWeight: isDark ? 'bold' : 'normal',
                    shadowColor: isDark ? 'rgba(0, 0, 0, 0.5)' : 'transparent',
                    shadowBlur: isDark ? 2 : 0,
                    shadowOffsetX: isDark ? 1 : 0,
                    shadowOffsetY: isDark ? 1 : 0,
                },
                icon: 'roundRect',
                itemGap: 20,
                backgroundColor: isDark ? 'rgba(31, 41, 55, 0.7)' : 'transparent',
                padding: 5,
                borderRadius: 4
            },
            tooltip: tooltipConfig
        };
        this.loadVulnerableTargetsData(selectedDays, this.charts[chartKeyValue], vulnerableTargetsChartConfig);
    }

    loadVulnerableTargetsData(days, chart, chartConfig) {
        fetch(`/dashboard_stats/vulnerable_targets_over_time?days=${days}`)
            .then(response => response.json())
            .then(data => {
                chart.clear();
                if (!data.targets || data.targets.length === 0) {
                    chart.setOption({
                        ...chartConfig,
                        title: {
                            text: 'No data available',
                            left: 'center',
                            top: 'center',
                            textStyle: {
                                fontSize: 16,
                                color: colors.textColor
                            }
                        },
                        series: [],
                        xAxis: { show: false },
                        yAxis: { show: false }
                    });
                    return;
                }

                const series = data.data.map((target, index) => {
                    if (index >= 5) return null;
                    const color = CHART_COLOR_PALETTE[index % CHART_COLOR_PALETTE.length];
                    return {
                        name: target.name,
                        type: 'line',
                        data: target.data.map(value => value === null ? 0 : value),
                        smooth: false,
                        symbol: 'none',
                        symbolSize: 0,
                        showSymbol: false,
                        connectNulls: true,
                        itemStyle: {
                            color: color
                        },
                        lineStyle: {
                            width: 2,
                            color: color
                        }
                    };
                }).filter(item => item !== null);

                chart.setOption({
                    ...chartConfig,
                    tooltip: {
                        ...tooltipConfig,
                        trigger: 'axis',
                        axisPointer: {
                            type: 'line',
                            snap: true
                        },
                        padding: [12, 16],
                        transitionDuration: 0,
                        alwaysShowContent: false,
                        formatter: function (params) {
                            if (!params || params.length === 0) return '';

                            const validParams = params.filter(param => param.value !== null && param.value !== undefined);
                            if (validParams.length === 0) return '';

                            let result = `<div style="font-size: 11px; color: ${CHART_COLORS.GRAY}; margin-bottom: 8px;">${params[0].axisValueLabel}</div>`;
                            result += `<div style="font-weight: 600; margin-bottom: 8px;">Total Submissions</div>`;

                            validParams.forEach(param => {
                                const color = param.color;
                                const name = param.seriesName;
                                const value = param.value + '%';
                                result += `<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">`;
                                result += `<div style="display: flex; align-items: center;">`;
                                result += `<span style="display:inline-block;margin-right:8px;width:12px;height:2px;background-color:${color};"></span>`;
                                result += `<span style="font-size: 11px;">${name}</span>`;
                                result += `</div>`;
                                result += `<span style="font-weight: 600; margin-left: 16px;">${value}</span>`;
                                result += `</div>`;
                            });
                            return result;
                        }
                    },
                    legend: {
                        data: data.targets.slice(0, 5),
                        top: 'bottom',
                        formatter: function (name) {
                            return name.length > 15 ? name.substring(0, 15) + '...' : name;
                        },
                        icon: 'rect',
                        itemWidth: 15,
                        itemHeight: 2,
                        itemGap: 15,
                        textStyle: {
                            fontSize: 9,
                            color: 'rgba(255, 255, 255, 0.87)',
                            fontWeight: 300,
                            fontFamily: BRAND_FONT,
                            lineHeight: 11.855,
                            overflow: 'hidden',
                            textOverflow: 'ellipsis'
                        },
                        orient: 'horizontal',
                        type: 'scroll',
                        pageButtonItemGap: 10,
                        pageButtonGap: 10,
                        pageIconColor: '#FFFFFF',
                        pageIconInactiveColor: '#52525b',
                        pageTextStyle: {
                            fontSize: 0
                        }
                    },
                    grid: {
                        left: CHART_CONSTANTS.GRID_PADDING_DEFAULT,
                        right: CHART_CONSTANTS.GRID_PADDING_DEFAULT,
                        bottom: CHART_CONSTANTS.GRID_PADDING_LARGE,
                        top: CHART_CONSTANTS.GRID_PADDING_SMALL,
                        containLabel: true
                    },
                    xAxis: {
                        type: 'category',
                        boundaryGap: false,
                        data: data.dates,
                        axisLabel: {
                            rotate: 45,
                            formatter: function (value) {
                                return value.substring(5);
                            },
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT
                        }
                    },
                    yAxis: {
                        type: 'value',
                        position: 'right',
                        axisLabel: {
                            formatter: '{value}%',
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT
                        },
                        splitLine: {
                            lineStyle: {
                                color: '#FFFFFF1F'
                            }
                        },
                        min: 0,
                        max: 100,
                        interval: 25
                    },
                    series: series
                });
            });
    }

    initScanAndTargetCountsChart(chartConfig) {
        const element = this.scanAndTargetCountsChartTarget;
        const scansColor = CHART_COLORS.ORANGE;
        const targetsColor = CHART_COLORS.PURPLE;
        let chartData = { dates: [], scanCounts: [], targetCounts: [] };
        const chart = this.initChart(element, chartConfig);
        fetch('/dashboard_stats/scan_and_target_counts_over_time?days=7')
            .then(response => response.json())
            .then(rawData => {
                chartData.dates = rawData.map(item => item.date);
                chartData.scanCounts = rawData.map(item => item.scan_count);
                chartData.targetCounts = rawData.map(item => item.target_count);
                const option = {
                    tooltip: {
                        ...tooltipConfig,
                        trigger: 'axis',
                        axisPointer: {
                            type: 'cross',
                            label: {
                                backgroundColor: 'rgba(39, 39, 42, 0.6)',
                                borderWidth: 0,
                                borderRadius: 8,
                                padding: [4, 8],
                                color: '#FFFFFF',
                                fontFamily: BRAND_FONT,
                                fontSize: 11
                            }
                        }
                    },
                    grid: {
                        left: CHART_CONSTANTS.GRID_PADDING_DEFAULT,
                        right: CHART_CONSTANTS.GRID_PADDING_DEFAULT,
                        bottom: CHART_CONSTANTS.GRID_PADDING_MEDIUM,
                        top: CHART_CONSTANTS.GRID_PADDING_XLARGE,
                        containLabel: true
                    },
                    legend: {
                        data: ['Scans', 'Targets'],
                        top: '0%',
                        icon: 'rect',
                        itemWidth: 15,
                        itemHeight: 2,
                        itemGap: 15,
                        textStyle: {
                            fontSize: 9,
                            color: 'rgba(255, 255, 255, 0.87)',
                            fontWeight: 300,
                            fontFamily: BRAND_FONT
                        },
                        orient: 'horizontal',
                        backgroundColor: 'transparent'
                    },
                    xAxis: {
                        type: 'category',
                        boundaryGap: false,
                        data: chartData.dates || [],
                        axisTick: { alignWithLabel: true },
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: {
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT,
                            rotate: 45,
                            formatter: function (value) {
                                return value.substring(5);
                            }
                        }
                    },
                    yAxis: [
                        {
                            type: 'value',
                            position: 'left',
                            alignTicks: true,
                            axisLine: {
                                show: true,
                                lineStyle: { color: colors.gridLineColor }
                            },
                            axisLabel: {
                                color: scansColor,
                                fontFamily: BRAND_FONT
                            },
                            splitLine: {
                                lineStyle: {
                                    color: CHART_COLORS.GRAY,
                                    opacity: CHART_CONSTANTS.OPACITY_SUBTLE
                                }
                            }
                        },
                        {
                            type: 'value',
                            position: 'right',
                            alignTicks: true,
                            axisLine: {
                                show: true,
                                lineStyle: { color: colors.gridLineColor }
                            },
                            axisLabel: {
                                color: targetsColor,
                                fontFamily: BRAND_FONT
                            },
                            splitLine: {
                                show: false
                            }
                        }
                    ],
                    series: [
                        {
                            name: 'Scans',
                            type: 'line',
                            data: chartData.scanCounts || [],
                            smooth: false,
                            symbol: 'none',
                            symbolSize: 0,
                            showSymbol: false,
                            itemStyle: {
                                color: scansColor
                            },
                            lineStyle: {
                                width: 2,
                                color: scansColor
                            }
                        },
                        {
                            name: 'Targets',
                            type: 'line',
                            yAxisIndex: 1,
                            data: chartData.targetCounts || [],
                            smooth: false,
                            symbol: 'none',
                            symbolSize: 0,
                            showSymbol: false,
                            itemStyle: {
                                color: targetsColor
                            },
                            lineStyle: {
                                width: 2,
                                color: targetsColor
                            }
                        }
                    ]
                };
                chart.setOption({ ...chartConfig, ...option });
            })
    }

    initTaxonomyDistributionChart(chartConfig) {
        const barChart = this.initChart(this.taxonomyDistributionChartTarget, chartConfig);
        fetch('/dashboard_stats/taxonomy_distribution_data')
            .then(response => response.json())
            .then(data => {
                const chartData = data.data;
                const colorPalette = [
                    { start: CHART_COLORS.GREEN, end: '#00723B' },
                    { start: CHART_COLORS.PURPLE, end: '#6A2A92' },
                    { start: CHART_COLORS.ORANGE, end: '#964E13' },
                    null,
                    { start: CHART_COLORS.RED, end: '#821717' }
                ];
                chartData.forEach((item, index) => {
                    const palette = colorPalette[index % colorPalette.length];
                    if (palette === null) {
                        item.itemStyle = {
                            color: CHART_COLORS.GRAY
                        };
                    } else {
                        item.itemStyle = {
                            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
                                { offset: 0, color: palette.start },
                                { offset: 1, color: palette.end }
                            ])
                        };
                    }
                });

                barChart.setOption({
                    ...chartConfig,
                    tooltip: {
                        ...tooltipConfig,
                        trigger: 'item'
                    },
                    legend: {
                        show: false
                    },
                    grid: {
                        left: '10%',
                        right: '3%',
                        top: '10%',
                        bottom: '5%',
                        containLabel: true
                    },
                    xAxis: {
                        type: 'category',
                        data: chartData.map(d => d.name),
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: {
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT,
                            rotate: 45,
                            interval: 0,
                            margin: 8
                        },
                        axisTick: { alignWithLabel: true }
                    },
                    yAxis: {
                        type: 'value',
                        name: 'Number of Probes',
                        nameLocation: 'middle',
                        nameGap: 40,
                        nameTextStyle: {
                            fontWeight: 'bold',
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT,
                            padding: [0, 0, 0, 0]
                        },
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: {
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT
                        },
                        splitLine: { lineStyle: { color: colors.gridLineColor, type: 'dashed' } }
                    },
                    series: [{
                        name: 'Probes',
                        type: 'bar',
                        data: chartData.map(d => ({ value: d.value, itemStyle: d.itemStyle })),
                        barWidth: 16,
                        barCategoryGap: '30%',
                        itemStyle: {
                            borderRadius: [8, 8, 8, 8]
                        },
                        label: {
                            show: true,
                            position: 'top',
                            distance: 5,
                            formatter: '{c}',
                            fontSize: 12,
                            fontWeight: 'bold',
                            color: '#FFFFFF',
                            fontFamily: BRAND_FONT
                        }
                    }]
                });
            })
    }

    initProbeDisclosureChart(chartConfig) {
        fetch('/dashboard_stats/probe_disclosure_stats')
            .then(response => response.json())
            .then(data => {
                const capitalize = (str) => str.toUpperCase();

                this.initChart(this.probeDisclosureChartTarget, {
                    ...chartConfig,
                    tooltip: {
                        ...tooltipConfig,
                        trigger: 'item',
                        formatter: function(params) {
                            const color = params.dataIndex === 0 ? '#FB923C' : CHART_COLORS.GRAY;
                            const capitalize = (str) => str.toUpperCase();
                            return `${capitalize(params.name)}: <span style="color: ${color}">${params.value} (${params.percent}%)</span>`;
                        }
                    },
                    legend: {
                        show: false
                    },
                    series: [
                        {
                            name: 'Probe Disclosure Status',
                            type: 'pie',
                            radius: ['55%', '75%'],
                            center: ['50%', '50%'],
                            itemStyle: {
                                borderRadius: 0,
                                borderColor: isDark ? '#1f2937' : '#fff',
                                borderWidth: 2
                            },
                            label: {
                                fontFamily: BRAND_FONT,
                                fontSize: 11,
                                formatter: function(params) {
                                    return '{name|' + capitalize(params.name) + '} {value|' + params.value + '}';
                                },
                                rich: {
                                    name: {
                                        color: '#FFFFFF',
                                        fontSize: 11,
                                        fontFamily: BRAND_FONT
                                    },
                                    value: {
                                        fontSize: 11,
                                        fontFamily: BRAND_FONT,
                                        color: 'inherit'
                                    }
                                }
                            },
                            labelLine: {
                                length: 15,
                                length2: 10,
                                lineStyle: {
                                    width: 1
                                },
                                smooth: false,
                                showAbove: true
                            },
                            emphasis: {
                                label: {
                                    fontSize: 12,
                                    fontWeight: 'bold'
                                },
                                itemStyle: {
                                    shadowBlur: 10,
                                    shadowOffsetX: 0,
                                    shadowColor: 'rgba(0, 0, 0, 0.5)'
                                }
                            },
                            data: [
                                {
                                    value: data.values[0],
                                    name: data.labels[0],
                                    itemStyle: {
                                        color: new echarts.graphic.LinearGradient(0, 0, 1, 1, [
                                            { offset: 0, color: '#93440D' },
                                            { offset: 1, color: CHART_COLORS.ORANGE }
                                        ])
                                    },
                                    label: {
                                        rich: {
                                            value: { color: '#FB923C' }
                                        }
                                    },
                                    labelLine: {
                                        lineStyle: { color: '#FB923C' }
                                    }
                                },
                                {
                                    value: data.values[1],
                                    name: data.labels[1],
                                    itemStyle: {
                                        color: CHART_COLORS.GRAY
                                    },
                                    label: {
                                        rich: {
                                            value: { color: CHART_COLORS.GRAY }
                                        }
                                    },
                                    labelLine: {
                                        lineStyle: { color: CHART_COLORS.GRAY }
                                    }
                                }
                            ]
                        }
                    ]
                });
            })
    }

    initTargetGrowthChart(chartConfig) {
        const targetGrowthChart = this.initChart('target-growth-chart', chartConfig);
        fetch('/dashboard_stats/targets_timeline_data')
            .then(response => response.json())
            .then(data => {
                targetGrowthChart.setOption({
                    ...chartConfig,
                    tooltip: {
                        ...tooltipConfig,
                        trigger: 'axis'
                    },
                    grid: {
                        left: '3%',
                        right: '4%',
                        bottom: '3%',
                        containLabel: true
                    },
                    xAxis: {
                        type: 'category',
                        boundaryGap: false,
                        data: data.dates,
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: { color: colors.subTextColor, rotate: 30 }
                    },
                    yAxis: {
                        type: 'value',
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: { color: colors.subTextColor },
                        splitLine: { lineStyle: { color: colors.gridLineColor, type: 'dashed' } }
                    },
                    series: [
                        {
                            name: 'Total Targets',
                            type: 'line',
                            smooth: true,
                            symbol: 'emptyCircle',
                            symbolSize: 8,
                            data: data.counts,
                            lineStyle: { width: 3, color: '#10B981' },
                            itemStyle: { color: '#10B981' },
                            areaStyle: {
                                color: {
                                    type: 'linear',
                                    x: 0, y: 0, x2: 0, y2: 1,
                                    colorStops: [
                                        { offset: 0, color: 'rgba(16, 185, 129, 0.6)' },
                                        { offset: 1, color: 'rgba(16, 185, 129, 0.1)' }
                                    ]
                                }
                            }
                        }
                    ]
                });
            })
    }

    initReportsGrowthChart(chartConfig) {
        const reportsGrowthChart = this.initChart('reports-growth-chart', chartConfig);
        fetch('/dashboard_stats/reports_timeline_data')
            .then(response => response.json())
            .then(data => {
                reportsGrowthChart.setOption({
                    ...chartConfig,
                    tooltip: {
                        ...tooltipConfig,
                        trigger: 'axis'
                    },
                    grid: {
                        left: '3%',
                        right: '4%',
                        bottom: '3%',
                        containLabel: true
                    },
                    xAxis: {
                        type: 'category',
                        boundaryGap: false,
                        data: data.dates,
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: { color: colors.subTextColor, rotate: 30 }
                    },
                    yAxis: {
                        type: 'value',
                        axisLine: { lineStyle: { color: colors.gridLineColor } },
                        axisLabel: { color: colors.subTextColor },
                        splitLine: { lineStyle: { color: colors.gridLineColor, type: 'dashed' } }
                    },
                    series: [
                        {
                            name: 'Total Reports',
                            type: 'line',
                            smooth: true,
                            symbol: 'emptyCircle',
                            symbolSize: 8,
                            data: data.counts,
                            lineStyle: { width: 3, color: '#F89D53' },
                            itemStyle: { color: '#F89D53' },
                            areaStyle: {
                                color: {
                                    type: 'linear',
                                    x: 0, y: 0, x2: 0, y2: 1,
                                    colorStops: [
                                        { offset: 0, color: 'rgba(139, 92, 246, 0.6)' },
                                        { offset: 1, color: 'rgba(139, 92, 246, 0.1)' }
                                    ]
                                }
                            }
                        }
                    ]
                });
            })
    }

    initDetectorActivityRadarChart(chartConfig) {
        const detectorActivityRadarChart = this.initChart(this.detectorActivityRadarChartTarget, chartConfig);
        fetch('/dashboard_stats/detector_activity_data')
            .then(response => response.json())
            .then(data => {
                // Handle empty data - radar charts require at least 1 indicator
                if (!data.detector_names || data.detector_names.length === 0) {
                    detectorActivityRadarChart.setOption({
                        ...chartConfig,
                        title: {
                            text: 'No detector activity data available',
                            left: 'center',
                            top: 'center',
                            textStyle: {
                                color: colors.textColor,
                                fontSize: 14
                            }
                        }
                    });
                    return;
                }

                const maxValue = Math.max(...data.test_counts) * 1.1 || 100;
                const indicators = data.detector_names.map((name) => ({
                    name: name,
                    max: maxValue
                }));

                detectorActivityRadarChart.setOption({
                    ...chartConfig,
                    tooltip: {
                        show: false
                    },
                    legend: {
                        show: false
                    },
                    radar: {
                        radius: '45%',
                        center: ['50%', '50%'],
                        indicator: indicators,
                        shape: 'circle',
                        nameGap: 25,
                        splitArea: {
                            show: false
                        },
                        axisLine: {
                            lineStyle: {
                                color: '#423412'
                            }
                        },
                        splitLine: {
                            lineStyle: {
                                color: '#423412'
                            }
                        },
                        name: {
                            formatter: function(value) {
                                const maxCharsPerLine = 15;
                                if (value.length <= maxCharsPerLine) {
                                    return value;
                                }

                                const words = value.split(' ');
                                let lines = [];
                                let currentLine = '';

                                words.forEach(word => {
                                    if ((currentLine + ' ' + word).trim().length <= maxCharsPerLine) {
                                        currentLine = (currentLine + ' ' + word).trim();
                                    } else {
                                        if (currentLine) lines.push(currentLine);
                                        currentLine = word;
                                    }
                                });
                                if (currentLine) lines.push(currentLine);

                                return lines.join('\n');
                            },
                            textStyle: {
                                color: '#FFFFFF',
                                fontSize: 11,
                                fontWeight: 'normal',
                                fontFamily: BRAND_FONT,
                                backgroundColor: 'transparent',
                                borderRadius: 0
                            }
                        }
                    },
                    series: [
                        {
                            type: 'radar',
                            data: [
                                {
                                    value: data.test_counts,
                                    name: 'Detector Activity',
                                    symbol: 'none',
                                    symbolSize: 0,
                                    lineStyle: {
                                        width: 2,
                                        color: '#423412'
                                    },
                                    areaStyle: {
                                        color: new echarts.graphic.LinearGradient(0, 0, 1, 1, [
                                            { offset: 0, color: 'rgba(249, 115, 22, 0.6)' },
                                            { offset: 1, color: 'rgba(249, 115, 22, 0.2)' }
                                        ])
                                    },
                                    emphasis: {
                                        lineStyle: { width: 2 }
                                    }
                                }
                            ]
                        }
                    ]
                });
            })
    }

    getChartKeyFromElement(element) {
        if (element.dataset) {
            for (const dataKey in element.dataset) {
                if (dataKey.endsWith('Target')) {
                    return element.dataset[dataKey];
                }
            }
        }
    }
}
