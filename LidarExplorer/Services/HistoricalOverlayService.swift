//
//  HistoricalOverlayService.swift
//  LidarExplorer
//
//  Created by Claude on 1/19/26.
//

import Foundation
import MapKit

class HistoricalOverlayService {
    static let shared = HistoricalOverlayService()

    private init() {}

    // MARK: - Native American Territories

    func getNativeAmericanTerritories() -> [HistoricalTerritory] {
        return [
            // Cherokee Nation (Southeastern US)
            HistoricalTerritory(
                name: "Cherokee Nation",
                type: .nativeAmericanTerritory,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 35.5, longitude: -84.5),
                    CLLocationCoordinate2D(latitude: 36.0, longitude: -84.0),
                    CLLocationCoordinate2D(latitude: 36.5, longitude: -83.0),
                    CLLocationCoordinate2D(latitude: 36.0, longitude: -82.0),
                    CLLocationCoordinate2D(latitude: 35.0, longitude: -82.5),
                    CLLocationCoordinate2D(latitude: 34.5, longitude: -83.5),
                    CLLocationCoordinate2D(latitude: 35.0, longitude: -84.8)
                ],
                description: "Historic Cherokee territory in the southeastern United States, spanning parts of modern-day Georgia, Tennessee, North Carolina, and South Carolina.",
                timePeriod: "Pre-1838",
                culturalGroup: "Cherokee"
            ),

            // Lakota Sioux (Great Plains)
            HistoricalTerritory(
                name: "Lakota Territory",
                type: .nativeAmericanTerritory,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 46.0, longitude: -104.0),
                    CLLocationCoordinate2D(latitude: 46.5, longitude: -100.0),
                    CLLocationCoordinate2D(latitude: 45.5, longitude: -98.0),
                    CLLocationCoordinate2D(latitude: 44.0, longitude: -98.5),
                    CLLocationCoordinate2D(latitude: 43.0, longitude: -101.0),
                    CLLocationCoordinate2D(latitude: 43.5, longitude: -104.5)
                ],
                description: "Traditional lands of the Lakota Sioux, including the sacred Black Hills and much of the northern Great Plains.",
                timePeriod: "Pre-1868",
                culturalGroup: "Lakota Sioux"
            ),

            // Navajo Nation (Southwest)
            HistoricalTerritory(
                name: "Dinétah (Navajo Homeland)",
                type: .nativeAmericanTerritory,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 36.8, longitude: -109.5),
                    CLLocationCoordinate2D(latitude: 37.0, longitude: -107.5),
                    CLLocationCoordinate2D(latitude: 36.0, longitude: -107.0),
                    CLLocationCoordinate2D(latitude: 35.0, longitude: -108.5),
                    CLLocationCoordinate2D(latitude: 35.5, longitude: -110.5)
                ],
                description: "The traditional Navajo homeland in the Four Corners region, encompassing parts of Arizona, New Mexico, Utah, and Colorado.",
                timePeriod: "1400s-Present",
                culturalGroup: "Navajo (Diné)"
            ),

            // Iroquois Confederacy (Northeast)
            HistoricalTerritory(
                name: "Haudenosaunee Territory",
                type: .nativeAmericanTerritory,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 43.5, longitude: -79.0),
                    CLLocationCoordinate2D(latitude: 44.0, longitude: -76.0),
                    CLLocationCoordinate2D(latitude: 43.0, longitude: -74.0),
                    CLLocationCoordinate2D(latitude: 42.0, longitude: -75.0),
                    CLLocationCoordinate2D(latitude: 42.5, longitude: -78.5)
                ],
                description: "Territory of the Iroquois Confederacy (Haudenosaunee) in present-day New York state and surrounding regions.",
                timePeriod: "1100s-1779",
                culturalGroup: "Haudenosaunee (Iroquois)"
            )
        ]
    }

    // MARK: - Civil War Sites

    func getCivilWarSites() -> [HistoricalSite] {
        return [
            HistoricalSite(
                name: "Gettysburg Battlefield",
                type: .civilWarSite,
                coordinate: CLLocationCoordinate2D(latitude: 39.8110, longitude: -77.2311),
                description: "Site of the bloodiest battle of the American Civil War and President Lincoln's Gettysburg Address.",
                timePeriod: "July 1-3, 1863",
                significance: "Turning point of the Civil War",
                dateEstablished: "1863"
            ),

            HistoricalSite(
                name: "Appomattox Court House",
                type: .civilWarSite,
                coordinate: CLLocationCoordinate2D(latitude: 37.3760, longitude: -78.7979),
                description: "Location where General Robert E. Lee surrendered to General Ulysses S. Grant, effectively ending the Civil War.",
                timePeriod: "April 9, 1865",
                significance: "End of the Civil War",
                dateEstablished: "1865"
            ),

            HistoricalSite(
                name: "Fort Sumter",
                type: .civilWarSite,
                coordinate: CLLocationCoordinate2D(latitude: 32.7520, longitude: -79.8747),
                description: "Site of the first battle of the American Civil War.",
                timePeriod: "April 12-13, 1861",
                significance: "Beginning of the Civil War",
                dateEstablished: "1861"
            ),

            HistoricalSite(
                name: "Antietam Battlefield",
                type: .civilWarSite,
                coordinate: CLLocationCoordinate2D(latitude: 39.4752, longitude: -77.7432),
                description: "Site of the bloodiest single-day battle in American history.",
                timePeriod: "September 17, 1862",
                significance: "Led to the Emancipation Proclamation",
                dateEstablished: "1862"
            ),

            HistoricalSite(
                name: "Vicksburg Battlefield",
                type: .civilWarSite,
                coordinate: CLLocationCoordinate2D(latitude: 32.3520, longitude: -90.8493),
                description: "Site of the Union siege that gave the North control of the Mississippi River.",
                timePeriod: "May 18 - July 4, 1863",
                significance: "Split the Confederacy in two",
                dateEstablished: "1863"
            ),

            HistoricalSite(
                name: "Shiloh Battlefield",
                type: .civilWarSite,
                coordinate: CLLocationCoordinate2D(latitude: 35.1385, longitude: -88.3387),
                description: "Site of one of the earliest and bloodiest battles in the Western Theater.",
                timePeriod: "April 6-7, 1862",
                significance: "First major battle in the West",
                dateEstablished: "1862"
            )
        ]
    }

    // MARK: - Historical Trails

    func getHistoricalTrails() -> [HistoricalTrail] {
        return [
            // Oregon Trail (simplified section)
            HistoricalTrail(
                name: "Oregon Trail",
                coordinates: [
                    CLLocationCoordinate2D(latitude: 39.0997, longitude: -94.5783), // Independence, MO
                    CLLocationCoordinate2D(latitude: 40.8258, longitude: -96.6852), // Lincoln, NE
                    CLLocationCoordinate2D(latitude: 41.1400, longitude: -104.8202), // Cheyenne, WY
                    CLLocationCoordinate2D(latitude: 42.8651, longitude: -106.3131), // Casper, WY
                    CLLocationCoordinate2D(latitude: 43.6150, longitude: -116.2023), // Boise, ID
                    CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784) // Portland, OR
                ],
                description: "The primary route used by American pioneers traveling westward during the mid-1800s.",
                timePeriod: "1841-1869",
                lengthMiles: 2170
            ),

            // Santa Fe Trail
            HistoricalTrail(
                name: "Santa Fe Trail",
                coordinates: [
                    CLLocationCoordinate2D(latitude: 39.0997, longitude: -94.5783), // Independence, MO
                    CLLocationCoordinate2D(latitude: 38.0406, longitude: -97.9278), // Dodge City, KS
                    CLLocationCoordinate2D(latitude: 37.6922, longitude: -99.8964), // Western KS
                    CLLocationCoordinate2D(latitude: 36.4073, longitude: -103.2052), // Clayton, NM
                    CLLocationCoordinate2D(latitude: 35.6870, longitude: -105.9378) // Santa Fe, NM
                ],
                description: "A 19th-century transportation route through central North America that connected Missouri with Santa Fe.",
                timePeriod: "1821-1880",
                lengthMiles: 900
            ),

            // Trail of Tears
            HistoricalTrail(
                name: "Trail of Tears",
                coordinates: [
                    CLLocationCoordinate2D(latitude: 35.4676, longitude: -84.5120), // Cherokee lands
                    CLLocationCoordinate2D(latitude: 35.0456, longitude: -85.3097), // Chattanooga, TN
                    CLLocationCoordinate2D(latitude: 35.1495, longitude: -90.0490), // Memphis, TN
                    CLLocationCoordinate2D(latitude: 35.2010, longitude: -91.8318), // Little Rock, AR
                    CLLocationCoordinate2D(latitude: 35.4676, longitude: -94.3985), // Fort Smith, AR
                    CLLocationCoordinate2D(latitude: 35.4829, longitude: -97.5164) // Oklahoma City, OK
                ],
                description: "The forced relocation route of Cherokee people from their ancestral homelands to Indian Territory.",
                timePeriod: "1838-1839",
                lengthMiles: 1200
            ),

            // California Trail
            HistoricalTrail(
                name: "California Trail",
                coordinates: [
                    CLLocationCoordinate2D(latitude: 41.1400, longitude: -104.8202), // Cheyenne, WY
                    CLLocationCoordinate2D(latitude: 41.5868, longitude: -109.2643), // Rock Springs, WY
                    CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910), // Salt Lake City, UT
                    CLLocationCoordinate2D(latitude: 39.5296, longitude: -119.8138), // Reno, NV
                    CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944) // Sacramento, CA
                ],
                description: "An emigrant trail that carried over 250,000 gold-seekers and farmers to California during the 1840s-1850s.",
                timePeriod: "1841-1869",
                lengthMiles: 2000
            )
        ]
    }

    // MARK: - Archaeological Sites

    func getArchaeologicalSites() -> [HistoricalSite] {
        return [
            HistoricalSite(
                name: "Mesa Verde",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 37.2309, longitude: -108.4618),
                description: "Ancient Ancestral Puebloan cliff dwellings and archaeological sites.",
                timePeriod: "600-1300 CE",
                significance: "Exceptional preservation of Ancestral Puebloan culture",
                dateEstablished: "1906"
            ),

            HistoricalSite(
                name: "Cahokia Mounds",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 38.6551, longitude: -90.0659),
                description: "Largest pre-Columbian settlement north of Mexico, with over 120 earthen mounds.",
                timePeriod: "600-1400 CE",
                significance: "Largest prehistoric Native American city north of Mexico",
                dateEstablished: "1050-1350 CE"
            ),

            HistoricalSite(
                name: "Chaco Canyon",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 36.0600, longitude: -107.9647),
                description: "Major center of Ancestral Puebloan culture with monumental architecture and astronomical alignments.",
                timePeriod: "850-1250 CE",
                significance: "Center of ceremonial, trade, and administrative activities",
                dateEstablished: "850 CE"
            ),

            HistoricalSite(
                name: "Poverty Point",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 32.6379, longitude: -91.4087),
                description: "Large prehistoric earthwork site built by the Poverty Point culture.",
                timePeriod: "1700-1100 BCE",
                significance: "One of North America's most impressive ancient engineering feats",
                dateEstablished: "1700 BCE"
            ),

            HistoricalSite(
                name: "Serpent Mound",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 39.0271, longitude: -83.4307),
                description: "A 1,348-foot-long prehistoric effigy mound in the shape of a serpent.",
                timePeriod: "1070 CE",
                significance: "Largest surviving prehistoric effigy mound in the world",
                dateEstablished: "1070 CE"
            ),

            HistoricalSite(
                name: "Hopewell Culture Site",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 39.3639, longitude: -83.0087),
                description: "Complex of earthworks and mounds built by the Hopewell culture.",
                timePeriod: "100 BCE-500 CE",
                significance: "Center of extensive trade network and ceremonial activity",
                dateEstablished: "100 BCE"
            ),

            HistoricalSite(
                name: "Taos Pueblo",
                type: .archaeologicalSite,
                coordinate: CLLocationCoordinate2D(latitude: 36.4372, longitude: -105.5445),
                description: "Ancient pueblo continuously inhabited for over 1,000 years.",
                timePeriod: "1000 CE-Present",
                significance: "One of the oldest continuously inhabited communities in the United States",
                dateEstablished: "1000 CE"
            )
        ]
    }

    // MARK: - Convenience Methods

    func getAllTerritories() -> [HistoricalTerritory] {
        return getNativeAmericanTerritories()
    }

    func getAllTrails() -> [HistoricalTrail] {
        return getHistoricalTrails()
    }

    func getAllSites() -> [HistoricalSite] {
        return getCivilWarSites() + getArchaeologicalSites()
    }

    func getSites(ofType type: HistoricalOverlayType) -> [HistoricalSite] {
        return getAllSites().filter { $0.type == type }
    }
}
